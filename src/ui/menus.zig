//! Full-screen menus + browsers: the options menu, main menu, the
//! load-save browser, the editor mission browser, the credits panel, and
//! the settings panel (toggles/choices/sliders — see DESIGN → UI
//! Framework → Settings screen).

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const keybind_edit = @import("keybind_edit.zig");
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
const top_bar_height = ui_element.top_bar_height;
const menu_button_width = ui_element.menu_button_width;
const menu_button_font_size = ui_element.menu_button_font_size;
const main_menu_title_font_size = ui_element.main_menu_title_font_size;
const main_menu_title_gap = ui_element.main_menu_title_gap;
const middle_panel_header_height = ui_element.middle_panel_header_height;
const middle_panel_header_font_size = ui_element.middle_panel_header_font_size;
const lineHeight = ui_element.lineHeight;
const buildMissionFail = @import("screens.zig").buildMissionFail;
const spanRow = ui_tooltip.spanRow;
const negative_color = ui_tooltip.negative_color;
const emitPanelButton = emit.emitPanelButton;

/// Build the options menu: a full-screen 9-slice panel background with a
/// centered stack of `menu_button_width` buttons (same design as the main
/// menu). Context-specific: the button list depends on the current screen.
/// No close button anywhere — the menu closes via the `.escape` action
/// (the Escape keybind + the top-bar options button toggle it); that is
/// enough of a close path, and a "Continue" button would collide with
/// resume-game meanings on some screens.
/// Save carries `.save_game`. Rendered on top of the bottom bar when
/// the options-menu surface is open (`GameState.ui_surfaces
/// .options_menu_open`), like the error popup. See DESIGN → UI
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
    var buttons: [9]MenuButton = undefined;
    var button_count: usize = 0;

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
    // run data as a campaign save. Also hidden on the main menu — no
    // game is in progress (empty/throwaway player_data); Load Save is
    // that screen's save workflow. `save_game` is button-only (no
    // keybind), so hiding the button removes the path entirely.
    if (current_screen != .editor and current_screen != .main_menu and editor_run == null) {
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

        // Open the editor browser (your saved/imported missions + the
        // official campaign ones, two tabs): a row click replaces the
        // mission being edited (no unsaved-changes confirm — save first
        // if in doubt; ctrl+S is cheap). Also on ctrl+O (the binding
        // ships in default_settings.txt).
        buttons[button_count] = .{
            .label = "Open Mission",
            .action = .toggle_editor_browser,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Ctrl+O — browse your saved missions and the official ones",
            ))}) },
        };
        button_count += 1;

        // The fresh-mission open (also the editor browser's New Mission
        // button + ctrl+N): replaces the mission being edited with a
        // new one-level template mission (no unsaved-changes confirm,
        // same as an open — save first if in doubt).
        buttons[button_count] = .{
            .label = "New Mission",
            .action = .new_editor_mission,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Ctrl+N — replaces the mission being edited with a fresh one",
            ))}) },
        };
        button_count += 1;

        // Revalidate: re-certify the STORED validation replay against the
        // current saved content — the author's post-edit repair for edits
        // that don't affect the run (e.g. a decoration placed off the
        // playable area): the recorded run is replayed against the files
        // as they are now, and on success the replay is re-bound to the
        // new content hash. Missions without a stored replay are told to
        // run Validate first (the handler surfaces it).
        buttons[button_count] = .{
            .label = "Revalidate Mission",
            .action = .revalidate_editor_mission,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Re-checks the stored validation replay against the saved mission and re-binds it to the current content",
            ))}) },
        };
        button_count += 1;
    }

    // Export Game (web only — the persistent-dir-path-null signal, the
    // same web case the Export Save tooltip uses): downloads ziglop.zip,
    // the FULL game folder (settings, saves, custom missions) — the web
    // build's cross-session backup path (browser storage never persists
    // sessions). Present in EVERY variant (the options menu is the only
    // menu surface reachable mid-level, so in-session backups are always
    // possible); a game in progress writes the autosave FIRST (the
    // handler), so mid-level progress is in the zip. Native has no button
    // — the real persistent dir IS the game folder.
    if (persistent_dir_path == null) {
        buttons[button_count] = .{
            .label = "Export Game",
            .action = .export_game,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Downloads ziglop.zip — your full game folder (settings, saves, custom missions)",
            ))}) },
        };
        button_count += 1;
    }

    // Settings: opens the settings overlay on top of this one (drill-in).
    // Present in every context the options menu appears in.
    buttons[button_count] = .{ .label = "Settings", .action = .open_settings };
    button_count += 1;

    // The main-menu variant: no session verbs (nothing to restart/exit/
    // export) and no Exit to Main Menu (already there) — Credits + the
    // native-only Exit Game join Settings. On web, Exit Game is omitted
    // (closing the tab is the user's, not ours; the handler's comptime os
    // gate is the defensive half for a future keybind).
    if (current_screen == .main_menu) {
        buttons[button_count] = .{ .label = "Credits", .action = .open_credits };
        button_count += 1;
        if (@import("builtin").os.tag != .emscripten) {
            buttons[button_count] = .{ .label = "Exit Game", .action = .exit_game };
            button_count += 1;
        }
    } else {
        buttons[button_count] = .{ .label = "Exit to Main Menu", .action = .exit_to_menu };
        button_count += 1;
    }

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
/// to resume — populated PlayerData). Settings + Credits live in the
/// OPTIONS MENU's main-menu variant (reached via the top-bar options
/// button / Escape — one convention from every screen); this stack holds
/// only the session-flow verbs + mode entries.
/// The web storage disclaimer's fonts + gap (main menu, web only — see
/// DESIGN → File System & IO → Web storage model): a header line + a body
/// line, centered above the title. Band heights are the font sizes (the
/// title's convention — the labels are single-line).
const main_menu_disclaimer_header_font_size: i32 = 60;
const main_menu_disclaimer_body_font_size: i32 = 44;
const main_menu_disclaimer_gap: i32 = 24;

pub fn buildMainMenu(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    continue_available: bool,
    /// The session's persistent dir path (the buildOptionsMenu convention;
    /// threaded from `SessionState.persistent_dir_path`). Null on web — the
    /// web signal both web-only surfaces derive from: the Import Game
    /// button + the web storage disclaimer (a browser upload / a download is
    /// the cross-session path when there is no real dir). Native has a path —
    /// no button, no disclaimer (the real dir IS the game folder).
    persistent_dir_path: ?[]const u8,
    button_color: Color,
) !void {
    const on_web = persistent_dir_path == null;
    const MenuButton = struct { label: []const u8, action: Action, tooltip: ?Tooltip = null };
    var buttons: [5]MenuButton = undefined;
    var button_count: usize = 0;
    if (continue_available) {
        buttons[button_count] = .{ .label = "Continue", .action = .continue_game };
        button_count += 1;
    }
    buttons[button_count] = .{ .label = "New Game", .action = .new_game };
    button_count += 1;
    buttons[button_count] = .{ .label = "Load Save", .action = .toggle_load_save_menu };
    button_count += 1;
    // Import Game (web only — the on_web signal): uploads a ziglop.zip OVER
    // the game folder — the web build's cross-session RESTORE path (browser
    // storage never persists sessions; a downloaded archive is the only
    // durable home, Export Game writes it). The overlay lands via the
    // every-frame marker poll + the session re-boots at the frame boundary
    // — see game_zip.zig + DESIGN → File System & IO → Web storage model.
    if (on_web) {
        buttons[button_count] = .{
            .label = "Import Game",
            .action = .import_game,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Uploads a ziglop.zip over your game folder (replaces the current session)",
            ))}) },
        };
        button_count += 1;
    }
    // Opens the editor browser (the tabbed modal — browse + create
    // editor content; the mission kind today). See DESIGN → Architecture
    // → Level Editor → The editor browser.
    buttons[button_count] = .{ .label = "Editor", .action = .toggle_editor_browser };
    button_count += 1;

    const total_height = rowWidth(@intCast(button_count), panel_button_height, ui_gap);
    // The web storage disclaimer (web only, the chosen wording — DESIGN →
    // File System & IO → Web storage model): two centered lines above the
    // title, part of the same centered block (the disclaimer band sits on
    // top, then the title band, then the buttons).
    const disclaimer_band_height: i32 = if (on_web)
        main_menu_disclaimer_header_font_size + main_menu_disclaimer_gap +
            main_menu_disclaimer_body_font_size + main_menu_title_gap
    else
        0;
    // The title + disclaimer + button stack center together as one block:
    // title band on top of the stack, both centered by one `placeCenter` over
    // the combined height. Gap between title and first button = `main_menu_title_gap`.
    const title = "taplop";
    const title_width = font_metrics.measureSpanWidth(text(title), main_menu_title_font_size);
    const block_height = disclaimer_band_height + main_menu_title_gap + main_menu_title_font_size + total_height;
    const origin = screen
        .placeCenter(menu_button_width, block_height)
        .position();

    if (on_web) {
        const disclaimer_header = "WEB DISCLAIMER:";
        const disclaimer_header_width = font_metrics.measureSpanWidth(
            text(disclaimer_header),
            main_menu_disclaimer_header_font_size,
        );
        try elements.append(allocator, .{ .text_label = .{
            .text = disclaimer_header,
            .screen_position = .{
                .x = origin.x + @divTrunc(menu_button_width - disclaimer_header_width, 2),
                .y = origin.y,
            },
            .font_size = main_menu_disclaimer_header_font_size,
            .blocks_input = false,
        } });
        const disclaimer_body = "Your saved data does not persist between sessions on web - use the Import Game and Export Game functionality to load and save data for cross-session usage";
        const disclaimer_body_width = font_metrics.measureSpanWidth(
            text(disclaimer_body),
            main_menu_disclaimer_body_font_size,
        );
        try elements.append(allocator, .{ .text_label = .{
            .text = disclaimer_body,
            .screen_position = .{
                .x = origin.x + @divTrunc(menu_button_width - disclaimer_body_width, 2),
                .y = origin.y + main_menu_disclaimer_header_font_size + main_menu_disclaimer_gap,
            },
            .font_size = main_menu_disclaimer_body_font_size,
            .blocks_input = false,
        } });
    }

    try elements.append(allocator, .{ .text_label = .{
        .text = title,
        .screen_position = .{
            .x = origin.x + @divTrunc(menu_button_width - title_width, 2),
            .y = origin.y + disclaimer_band_height,
        },
        .font_size = main_menu_title_font_size,
        .blocks_input = false,
    } });
    const buttons_origin_y = origin.y + disclaimer_band_height + main_menu_title_gap + main_menu_title_font_size;

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
            menu_button.tooltip,
        );
    }
}

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

/// One scrollbar: fixed-gray track + thumb (the shared scrollbar
/// constants) sized PROPORTIONALLY to the visible slice of the total
/// content and positioned by the row scroll offset — the shape every
/// row list on these surfaces uses (load-save browser, editor browser,
/// the settings keybinds columns). The track spans the full rows region;
/// the thumb is `track_height × visible / total` (min
/// `scrollbar_thumb_min_height`) sliding through the remaining travel.
fn emitScrollbar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    track_x: i32,
    track_y: i32,
    track_height: i32,
    visible_rows: usize,
    total_rows: usize,
    scroll_offset: i32,
) !void {
    try elements.append(allocator, .{ .solid_rect = .{
        .screen_position = .{ .x = track_x, .y = track_y },
        .width = scrollbar_width,
        .height = track_height,
        .color = ui_element.scrollbar_track_color,
    } });
    const visible_span_rows: i32 = @intCast(@min(total_rows, visible_rows));
    const max_scroll_row: i32 = @intCast(total_rows - @min(total_rows, visible_rows));
    const thumb_height = @max(
        ui_element.scrollbar_thumb_min_height,
        @divTrunc(track_height * visible_span_rows, @as(i32, @intCast(total_rows))),
    );
    const thumb_y = track_y + if (max_scroll_row == 0)
        0
    else
        @divTrunc(scroll_offset * (track_height - thumb_height), max_scroll_row);
    try elements.append(allocator, .{ .solid_rect = .{
        .screen_position = .{ .x = track_x, .y = thumb_y },
        .width = scrollbar_width,
        .height = thumb_height,
        .color = ui_element.scrollbar_thumb_color,
    } });
}

/// Import/Back button size (bottom corners). Import label is long, so the
/// buttons are wider than tall menu buttons but reuse the menu font.
const load_save_button_width: i32 = 768;

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
            try emitScrollbar(
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

/// The editor-browser kind tab row's spec — DERIVED at comptime from
/// `types.EditorKind` + `editorBrowserKindLabel` (the generated-lookup
/// pattern: the builder's tab row and its tests both walk this list, so a
/// new editor kind appears as a tab by adding the enum member — the
/// exhaustive label switch is the compile error until it's named).
const EditorBrowserKindSpec = struct {
    kind: types.EditorKind,
    label: []const u8,
};
const editor_kind_count = @typeInfo(types.EditorKind).@"enum".fields.len;
const editor_browser_kind_specs: [editor_kind_count]EditorBrowserKindSpec = blk: {
    var specs: [editor_kind_count]EditorBrowserKindSpec = undefined;
    for (@typeInfo(types.EditorKind).@"enum".fields, 0..) |field, index| {
        const kind: types.EditorKind = @enumFromInt(field.value);
        specs[index] = .{ .kind = kind, .label = editorBrowserKindLabel(kind) };
    }
    break :blk specs;
};

/// The kind tab's label — one per editor kind, exhaustive by construction
/// (no else-arm: a new EditorKind member is a compile error until named).
fn editorBrowserKindLabel(kind: types.EditorKind) []const u8 {
    return switch (kind) {
        .mission => "Mission",
    };
}

/// The New button's label, derived from the ACTIVE kind — one button, not
/// one per tab (the tab row already shows the kinds; buttons for content
/// that isn't on screen would be dead buttons). Exhaustive like the tab
/// label: a new editor kind names its New button here.
fn editorBrowserNewButtonLabel(kind: types.EditorKind) []const u8 {
    return switch (kind) {
        .mission => "New Mission",
    };
}

/// Build the editor browser: a full-screen modal panel mirroring the
/// load-save browser — the editor-kind tab row (Mission today; Hub /
/// Campaign tabs append when those editors land) with a New button
/// derived from the active kind, and the active kind's content. The
/// mission content mirrors the load-save browser: two tab buttons
/// top-left (Your Missions / Official — the sprite picker's tab
/// pattern), one clickable row per mission (display name; a click opens
/// it in the editor via `open_editor`), a Back button bottom-left. The
/// web-only Import button (zip upload) lands with the import slice.
/// Overflowing lists scroll with the load-save browser's whole-row model;
/// the scroll offset clamps here (authoritative — the view is the only
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
    // Full-screen modal background — blocks input to the editor UI behind
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
    // with their editors) — the tabs ARE the window's identity. Sits BELOW
    // the global top bar (the always-on-top layer would cover the tabs —
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

    // Content per kind — the kind row above is kind-independent chrome.
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

    // Bottom-left: Back (closes the browser — same toggle action that
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
    // button, not one per tab — the tab row already shows the kinds),
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
    // Import (web only — the load-save browser's Import discipline): opens
    // a file picker for a mission .zip; the picked zip extracts into
    // missions/ and the rescanned list shows it. Centered along the
    // bottom, between the Back and New buttons. Native has no button —
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
/// browser body). One content builder per editor kind — the parent
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
            // SlotRef pattern, via the newer Button-payload convention —
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
            try emitScrollbar(
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

// --- Credits screen (main menu, full screen) ---

const credits_header_font_size: i32 = 96;
/// Name line font size — larger than the roles line so each person reads
/// as a heading above their credits.
const credits_name_font_size: i32 = 72;
/// Roles line font size — the credit detail under each name.
const credits_role_font_size: i32 = 48;
/// Gap between a person's name and their roles line.
const credits_name_to_role_gap: i32 = 16;
/// Gap between each person block (name + roles).
const credits_person_gap: i32 = 64;
const credits_padding: i32 = 48;
const credits_button_gap: i32 = 48;
/// Back button size (bottom-left). Matches the load-save Back button so the
/// two main-menu overlays feel consistent.
const credits_button_width: i32 = 768;

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

const settings_padding: i32 = 48;
const settings_header_font_size: i32 = 96;
const settings_header_gap: i32 = 64;
pub const settings_row_font_size: i32 = 56;
const settings_row_height: i32 = 120;
const settings_row_gap: i32 = 32;
const settings_label_to_control_gap: i32 = 48;
const settings_button_gap: i32 = 48;
/// Back button size (bottom-left). Matches the load-save / credits Back
/// buttons so the main-menu overlays feel consistent.
const settings_button_width: i32 = 768;
/// Toggle button (On/Off) width — sits in the control area of a row.
const settings_toggle_width: i32 = 400;
/// Camera-zoom choice button width (one of 4).
const settings_choice_button_width: i32 = 240;
/// Player-color swatch size (one of 6).
const settings_swatch_size: i32 = 120;
const settings_swatch_gap: i32 = 16;
/// Slider track width.
const settings_slider_width: i32 = 800;
const settings_slider_value_gap: i32 = 32;

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
        .payload = .{ .setting = sref },
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

/// One Settings-tab control row's position on the two-column grid (6 rows
/// per column, right column after the left): `row_index` 0-5 is the left
/// column top-to-bottom, 6-11 the right. See `buildSettingsControls`.
fn settingsControlRowRect(
    content_x: i32,
    content_width: i32,
    rows_y_start: i32,
    row_index: i32,
) types.ScreenPosition {
    const column_width = @divTrunc(content_width - ui_gap, 2);
    const column = @divTrunc(row_index, 6);
    return .{
        .x = content_x + column * (column_width + ui_gap),
        .y = rows_y_start + @mod(row_index, 6) * (settings_row_height + settings_row_gap),
    };
}

/// The Settings tab's control rows (the 12 toggles/choices/sliders) —
/// called by `buildSettingsPanel` when the settings tab is active. The rows
/// vertically center as a group between `content_top` (below the tab row)
/// and the Back button. See DESIGN → UI Framework → Settings screen.
fn buildSettingsControls(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    settings: types.Settings,
    player_gradient: types.ColorGradient,
    button_color: Color,
    content_top: i32,
) !void {
    const content_width = screen.width - 2 * settings_padding;
    const content_x = screen.x + settings_padding;

    // Control rows. Each row: label (left) + control (right, flush
    // against the label — measured per-row so the control sits right after
    // the label text, not at a fixed column). Vertically stacked below the
    // header, centered as a group between header and Back button.

    // 12 rows (6 toggle/choice + 5 slider + 1 fps toggle):
    //   0. Master Volume (slider 0–100)
    //   1. Music Volume (slider 0–100)
    //   2. Sound Effects Volume (slider 0–100)
    //   3. Render FPS Cap (slider 0–256, 0 = Uncapped)
    //   4. Animation FPS (slider 1–16)
    //   5. VSync (toggle)
    //   6. Camera Zoom (4-button choice)
    //   7. Render Resolution (4-button choice)
    //   8. Player Color (6-swatch choice)
    //   9. Auto-skip attack step (toggle)
    //  10. Auto-target at cursor (toggle)
    //  11. Show FPS (toggle)
    // The 12 rows flow into TWO side-by-side columns of 6 (the wide
    // reference screen makes a single left-anchored column wasted space —
    // and a single 12-row column needs 1792px where the region between the
    // tab row and the Back button has ~1610: the last row would overlap the
    // Back button. It did even before the tab row — the tab row made the
    // pre-existing tightness a real collision). See
    // `settingsControlRowRect`.
    const rows_per_column: i32 = 6;
    const rows_total_height = rowWidth(rows_per_column, settings_row_height, settings_row_gap);
    const buttons_top = screen.y + screen.height - settings_padding -
        panel_button_height - settings_button_gap;
    const rows_y_start = content_top +
        @divTrunc(buttons_top - content_top - rows_total_height, 2);

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
            } }) catch @panic("failed to append settings label");
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
            } }) catch @panic("failed to append slider");
            // Value text right of the slider.
            const value_x = ctrl_x + settings_slider_width + settings_slider_value_gap;
            elems.append(alloc, .{ .text_label = .{
                .text = value_label,
                .screen_position = .{ .x = value_x, .y = y + @divTrunc(settings_row_height - settings_row_font_size, 2) },
                .font_size = settings_row_font_size,
                .blocks_input = false,
            } }) catch @panic("failed to append slider value");
        }
    }.run;

    var row_index: i32 = 0;

    // ── Slider rows (0–4) ──

    // Row 0: Master Volume (0–100).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.master_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Master Volume", .master_volume, 0, 100, settings.master_volume, value_label, row.x, row.y);
    }
    row_index += 1;

    // Row 1: Music Volume (0–100).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.music_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Music Volume", .music_volume, 0, 100, settings.music_volume, value_label, row.x, row.y);
    }
    row_index += 1;

    // Row 2: Sound Effects Volume (0–100).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.sound_effects_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Sound Effects Volume", .sound_effects_volume, 0, 100, settings.sound_effects_volume, value_label, row.x, row.y);
    }
    row_index += 1;

    // Row 3: Render FPS Cap (0–256, 0 = Uncapped).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label: []const u8 = if (settings.render_fps_cap == 0)
            "Uncapped"
        else
            std.fmt.allocPrint(allocator, "{d}", .{settings.render_fps_cap}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Render FPS Cap", .render_fps_cap, 0, 256, settings.render_fps_cap, value_label, row.x, row.y);
    }
    row_index += 1;

    // Row 4: Animation FPS (1–16).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label = std.fmt.allocPrint(allocator, "{d}", .{settings.animation_fps}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Animation FPS", .animation_fps, 1, 16, settings.animation_fps, value_label, row.x, row.y);
    }
    row_index += 1;

    // ── Toggle / choice rows (5–9) ──

    // Row 5: VSync toggle. Label is platform-specific: on web the setting
    // is a no-op — the browser's requestAnimationFrame paces rendering to
    // the display refresh regardless (rAF IS vsync on web; no page code can
    // out-run it). On native it's a real GLFW swap-interval toggle that only
    // applies at window creation, hence the restart note.
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const vsync_label = if (@import("builtin").os.tag == .emscripten)
            "VSync (always on in browser)"
        else
            "VSync (change requires restart)";
        const ctrl_x = emitLabel(elements, allocator, font_metrics, vsync_label, row.x, row.y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = row.y, .width = settings_toggle_width, .height = settings_row_height },
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
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Camera Zoom", row.x, row.y);
        const zoom_values = [_]u32{ 25, 50, 75, 100 };
        const zoom_labels = [_][]const u8{ "25%", "50%", "75%", "100%" };
        for (zoom_values, zoom_labels, 0..) |value, label, i| {
            try emitSettingButton(
                elements,
                allocator,
                font_metrics,
                .{
                    .x = ctrl_x + @as(i32, @intCast(i)) * (settings_choice_button_width + settings_swatch_gap),
                    .y = row.y,
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

    // Row 7: Render Resolution — 4 buttons (720p/1080p/1440p/2160p). The
    // choice is live-applied by `frame()`'s diff-and-apply; a failed apply
    // (GPU/texture-size limits) reverts the setting + popup, so the
    // highlighted button snaps back to what actually runs. See DESIGN →
    // Platform Seam → Render target resolution.
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Render Resolution", row.x, row.y);
        for (std.meta.tags(types.RenderResolution), 0..) |resolution, i| {
            try emitSettingButton(
                elements,
                allocator,
                font_metrics,
                .{
                    .x = ctrl_x + @as(i32, @intCast(i)) * (settings_choice_button_width + settings_swatch_gap),
                    .y = row.y,
                    .width = settings_choice_button_width,
                    .height = settings_row_height,
                },
                resolution.label(),
                settings_row_font_size,
                .{ .id = .render_resolution, .choice_value = @intFromEnum(resolution) },
                settings.render_resolution == resolution,
                button_color,
            );
        }
    }
    row_index += 1;

    // Row 8: Player Color — 6 swatches (player gradient indices 0–5).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Player Color", row.x, row.y);
        const swatch_y = row.y + @divTrunc(settings_row_height - settings_swatch_size, 2);
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
                .payload = .{ .setting = .{ .id = .player_color_index, .choice_value = @intCast(i) } },
                .highlighted = settings.player_color_index == i,
            } });
        }
    }
    row_index += 1;

    // Row 9: Auto-skip attack step toggle.
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Auto-skip Attack Step", row.x, row.y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = row.y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.auto_skip_attack_step_out_of_combat) "On" else "Off",
            settings_row_font_size,
            .{ .id = .auto_skip_attack_step_out_of_combat },
            false,
            button_color,
        );
    }
    row_index += 1;

    // Row 10: Auto-target at cursor toggle.
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Auto-target at Cursor", row.x, row.y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = row.y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.auto_target_at_cursor) "On" else "Off",
            settings_row_font_size,
            .{ .id = .auto_target_at_cursor },
            false,
            button_color,
        );
    }
    row_index += 1;

    // Row 11: Show FPS toggle.
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Show FPS", row.x, row.y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = row.y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.show_fps) "On" else "Off",
            settings_row_font_size,
            .{ .id = .show_fps },
            false,
            button_color,
        );
    }
}

/// Build the settings screen: a full-screen modal panel with a centered
/// "Settings" header, a column of control rows (toggle/choice — sliders
/// land in slice 3b), a Back button in the bottom-left, and Reset to
/// Defaults in the bottom-right (both tabs). The panel blocks input to the
/// surface behind it (main menu or the options menu). See DESIGN → UI
/// Framework → Settings screen.
pub fn buildSettingsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    settings: types.Settings,
    player_gradient: types.ColorGradient,
    button_color: Color,
    tab: types.SettingsTab,
    scroll_offset: *i32,
    edit_state: ?*const keybind_edit.KeybindEditState,
    picker_scroll_offset: *i32,
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

    // CONTENT TAB ROW (Settings / Keybinds), centered under the header.
    // Same emission shape as the editor-browser kind tabs: tinted panels,
    // the active tab's highlight outline is the indication. A tab switch
    // is a view affordance (direct UiState write, off the undo timeline —
    // the browser-tab convention); the scroll resets at the handler.
    const settings_tab_specs = [_]struct { label: []const u8, tab: types.SettingsTab }{
        .{ .label = "Settings", .tab = .settings },
        .{ .label = "Keybinds", .tab = .keybinds },
    };
    const tabs_y = header_y + lineHeight(settings_header_font_size) + @divTrunc(settings_header_gap, 2);
    var tabs_width_total: i32 = 0;
    for (settings_tab_specs) |spec| {
        tabs_width_total += font_metrics.measureSpanWidth(text(spec.label), settings_row_font_size) +
            2 * @divTrunc(settings_label_to_control_gap, 2) + ui_gap;
    }
    tabs_width_total -= ui_gap; // no trailing gap
    var tab_x = content_x + @divTrunc(content_width - tabs_width_total, 2);
    for (settings_tab_specs) |spec| {
        const label_width = font_metrics.measureSpanWidth(text(spec.label), settings_row_font_size);
        const tab_width = label_width + settings_label_to_control_gap;
        const active = spec.tab == tab;
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = .{ .x = tab_x, .y = tabs_y },
            .width = tab_width,
            .height = settings_row_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{ .x = tab_x, .y = tabs_y },
            .width = tab_width,
            .height = settings_row_height,
            .action = .select_settings_tab,
            .payload = .{ .settings_tab = spec.tab },
            .highlighted = active,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = spec.label,
            .screen_position = .{
                .x = tab_x + @divTrunc(settings_label_to_control_gap, 2),
                .y = tabs_y + @divTrunc(settings_row_height - settings_row_font_size, 2),
            },
            .font_size = settings_row_font_size,
            .blocks_input = false,
        } });
        tab_x += tab_width + ui_gap;
    }
    const content_top = tabs_y + settings_row_height + @divTrunc(settings_header_gap, 2);
    // Content per tab — the tab row above is tab-independent chrome.
    // Exhaustive switch: a new SettingsTab member is a compile error until
    // its content builder is routed here.
    switch (tab) {
        .settings => try buildSettingsControls(
            elements,
            allocator,
            font_metrics,
            screen,
            settings,
            player_gradient,
            button_color,
            content_top,
        ),
        .keybinds => try buildKeybindsContent(
            elements,
            allocator,
            font_metrics,
            screen,
            settings.input_bindings,
            scroll_offset,
            button_color,
            content_top,
            edit_state,
            picker_scroll_offset,
        ),
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

    // Reset to Defaults, bottom-right — mirrors the Back button's metrics.
    // Direct click, no confirm (the timestamped backup is the safety net);
    // the tooltip says what it does. The command rides the `.edit_keybind`
    // channel (`.reset_defaults` is exempt from the keybinds-tab gate — a
    // whole-settings command on a both-tabs button).
    const reset_button_rect: Rectangle = .{
        .x = screen.x + screen.width - settings_padding - settings_button_width,
        .y = button_y,
        .width = settings_button_width,
        .height = panel_button_height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = reset_button_rect.position(),
        .width = reset_button_rect.width,
        .height = reset_button_rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = reset_button_rect.position(),
        .width = reset_button_rect.width,
        .height = reset_button_rect.height,
        .action = .edit_keybind,
        .payload = .{ .keybind_command = .reset_defaults },
        .tooltip = .{ .header = try spanRow(allocator, text("Creates a backup of current settings and loads defaults")) },
    } });
    const reset_label_text = "Reset to Defaults";
    const reset_label_width = font_metrics.measureSpanWidth(text(reset_label_text), menu_button_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = reset_label_text,
        .screen_position = .{
            .x = reset_button_rect.x + @divTrunc(reset_button_rect.width - reset_label_width, 2),
            .y = reset_button_rect.y + @divTrunc(panel_button_height - menu_button_font_size, 2),
        },
        .font_size = menu_button_font_size,
        .blocks_input = false,
    } });
}

// --- Keybinds tab (the in-game rebinding list) ---
//
// Display-label helpers (input ids + actions + context sets -> human-readable
// labels), then the content builder. The ids/actions/context sets are the
// file-format truth; these labels are VIEW-ONLY sugar.

/// A key/button id's display label ("Ctrl", "Z", "PgUp", "LMB") — a view-only
/// prettification of the raw id. Known idioms map to short labels; "KeyX" /
/// "DigitN" strip their prefixes (slices INTO the id — the id outlives the
/// frame); anything else shows verbatim (the full W3C key table means a raw
/// id is always something recognizable).
fn keyIdDisplayLabel(id: []const u8) []const u8 {
    const fixed = std.StaticStringMap([]const u8).initComptime(.{
        .{ "ControlLeft", "Ctrl" },
        .{ "ControlRight", "Ctrl" },
        .{ "ShiftLeft", "Shift" },
        .{ "ShiftRight", "Shift" },
        .{ "AltLeft", "Alt" },
        .{ "AltRight", "Alt" },
        .{ "PageUp", "PgUp" },
        .{ "PageDown", "PgDn" },
        .{ "left", "LMB" },
        .{ "right", "RMB" },
        .{ "middle", "MMB" },
    });
    if (fixed.get(id)) |label| return label;
    if (std.mem.startsWith(u8, id, "Key") and id.len > 3) return id[3..];
    if (std.mem.startsWith(u8, id, "Digit") and id.len > 5) return id[5..];
    return id;
}

/// Comptime label builder: capitalize the first character, '_' -> ' '.
/// Built by comptime STRING CONCATENATION (each `++` produces a compiler
/// constant) — comptime-var buffers copied into a table do NOT materialize
/// into the binary (the labels arrive as scratch garbage); concatenated
/// comptime strings do (the `StaticStringMap` mechanism).
fn makePrettifiedLabel(comptime name: []const u8) []const u8 {
    comptime {
        var built: []const u8 = "";
        for (name, 0..) |character, character_index| {
            var mapped: u8 = character;
            if (character_index == 0) mapped = std.ascii.toUpper(character);
            if (character == '_') mapped = ' ';
            built = built ++ [_]u8{mapped};
        }
        return built;
    }
}

/// An action's display label ("undo" -> "Undo", "dump_event_log" -> "Dump
/// event log") — comptime-generated from the enum field names (machine-walked:
/// a new Action's label appears with no edit here).
fn actionDisplayLabel(action: types.Action) []const u8 {
    const labels = comptime blk: {
        @setEvalBranchQuota(20_000);
        const fields = @typeInfo(types.Action).@"enum".fields;
        var table: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, index| {
            table[index] = makePrettifiedLabel(field.name);
        }
        break :blk table;
    };
    return labels[@intFromEnum(action)];
}

/// A context set's display label ("Anytime", "Editor + Menu") —
/// comptime-generated for every subset of the five contexts, so any set an
/// `actionBindingContexts` case produces has a label with no edit here.
fn contextSetDisplayLabel(set: types.BindingContextSet) []const u8 {
    const labels = comptime blk: {
        @setEvalBranchQuota(50_000);
        var table: [1 << context_set_member_names.len][]const u8 = undefined;
        for (0..1 << context_set_member_names.len) |mask| {
            table[mask] = makeContextSetLabel(@intCast(mask));
        }
        break :blk table;
    };
    var mask: u32 = 0;
    if (set.anytime) mask |= 1 << 0;
    if (set.game) mask |= 1 << 1;
    if (set.editor) mask |= 1 << 2;
    if (set.menu) mask |= 1 << 3;
    if (set.error_popup) mask |= 1 << 4;
    return labels[mask];
}

/// The context members' display names, indexed by the mask bit each occupies
/// in `contextSetDisplayLabel`'s pack.
const context_set_member_names = [_][]const u8{ "Anytime", "Game", "Editor", "Menu", "Error popup" };

/// One subset's label, built by comptime string concatenation (see
/// `makePrettifiedLabel` for why concatenation, not comptime-var buffers).
fn makeContextSetLabel(comptime mask: u32) []const u8 {
    comptime {
        var built: []const u8 = "";
        for (context_set_member_names, 0..) |member_name, member_index| {
            if ((mask >> @intCast(member_index)) & 1 == 0) continue;
            if (built.len > 0) built = built ++ " + ";
            built = built ++ member_name;
        }
        if (built.len == 0) built = "None";
        return built;
    }
}

/// Horizontal padding inside a keybind key/action panel (label inset).
const keybind_panel_padding: i32 = 24;
/// Minimum panel width in the keybinds list. 9-slice panels render badly
/// below a certain width (the corner tiles dominate the panel — see TODO →
/// Cross-cutting polish), and single-character keys (I, U, 1) would
/// otherwise produce stub panels; the label centers in the panel so the
/// extra width reads as a button, not stretched text.
const keybind_min_panel_width: i32 = 160;

/// Sort display order: by action (enum declaration order — undo, redo,
/// escape, ...), stable so an action's multiple combos keep their file
/// order. The file's order is load order, not a display order.
fn bindingActionLessThan(_: void, left: types.InputBinding, right: types.InputBinding) bool {
    return @intFromEnum(left.action) < @intFromEnum(right.action);
}

/// The Keybinds tab's list + editing UI. READ side: one row per binding —
/// modifier/key panels ("+" between; prettified ids via `keyIdDisplayLabel`)
/// and the action panel directly after the combo, labeled "Action —
/// Contexts" (the derived context set). Rows sorted by action (stable) so an
/// action's combos sit adjacent.
///
/// EDIT side (TODO → Keybind editor slice 4): every row's combo area starts a
/// LISTENING rekey (the row swaps to a highlighted "Press a key…" panel; the
/// capture seam lives in `translateInput` — binding translation is
/// suppressed while any edit is active) and its action panel opens the
/// right-column action PICKER (the full scrollable action list); each row
/// carries X (remove — direct, no confirm) and + (add a combo for its
/// action). A capture or picker pick lands in a PENDING row: the proposed
/// combo + Confirm/Cancel buttons + the steal warning in the warn color
/// ("… currently fires Undo (game) — confirming will remove it"); confirming
/// applies (the settings mutation + debounced persistence). An add's
/// listening/pending row renders as an extra row at the top of the list.
/// The standalone Add button (top of the list) opens the picker to pick the
/// new binding's action first. See DESIGN → UI Framework → Settings screen.
fn buildKeybindsContent(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    bindings: []const types.InputBinding,
    scroll_offset: *i32,
    button_color: Color,
    content_top: i32,
    edit_state: ?*const keybind_edit.KeybindEditState,
    picker_scroll_offset: *i32,
) !void {
    const content_x = screen.x + settings_padding;
    const buttons_top = screen.y + screen.height - settings_padding -
        panel_button_height - settings_button_gap;
    const row_stride = settings_row_height + settings_row_gap;

    // The picker column owns the right half of the tab (when open); the
    // binding list ALWAYS occupies the left half — a stable layout that
    // doesn't reflow when the picker opens.
    const picker_x = screen.x + @divTrunc(screen.width, 2) + @divTrunc(ui_gap, 2);

    // The standalone Add button (top of the list — always visible): opens
    // the picker to pick the new binding's action first.
    _ = try emitKeybindCommandPanel(
        elements,
        allocator,
        font_metrics,
        "+ Add keybind",
        content_x,
        content_top,
        button_color,
        .add_open,
        false,
        null,
    );

    const list_top = content_top + row_stride;
    const region_height = buttons_top - list_top;
    const visible_rows: usize = @intCast(@max(1, @divTrunc(region_height, row_stride)));

    // The ADD proposal (an add's listening or pending phase) renders as
    // an extra row below its action's row group — where the confirmed
    // combo will appear (the display is action-sorted) — or at the top of
    // the list when the action has no bindings yet (the standalone add of
    // a fresh action).
    const add_edit: ?keybind_edit.KeybindEdit = if (edit_state) |edit_source| switch (edit_source.edit) {
        .listening => |target| switch (target) {
            .add => |action| .{ .listening = .{ .add = action } },
            else => null,
        },
        .pending => |pending| if (pending.replace_index == null) .{ .pending = pending } else null,
        else => null,
    } else null;

    // Display order: indices sorted by action (stable) — each row carries
    // its original binding index for edit targeting.
    const order = try allocator.alloc(usize, bindings.len);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, bindings, bindingIndexActionLessThan);

    const RowEntry = union(enum) {
        add_edit,
        binding: usize,
    };

    // The proposal's insert position: after the LAST row of its action's
    // group in display order (0 = top — the action has no bindings yet).
    var add_insert_position: usize = 0;
    if (add_edit != null) {
        const target_action: ?types.Action = switch (add_edit.?) {
            .listening => |target| switch (target) {
                .add => |action| action,
                else => null,
            },
            .pending => |pending| pending.binding.action,
            else => null,
        };
        if (target_action) |action| {
            for (order, 0..) |binding_index, position| {
                if (bindings[binding_index].action == action) add_insert_position = position + 1;
            }
        }
    }

    var rows: std.ArrayList(RowEntry) = .empty;
    for (order, 0..) |binding_index, position| {
        if (add_edit != null and position == add_insert_position) try rows.append(allocator, .add_edit);
        try rows.append(allocator, .{ .binding = binding_index });
    }
    if (add_edit != null and add_insert_position >= order.len) try rows.append(allocator, .add_edit);

    // Clamp the scroll (authoritative upper bound).
    if (rows.items.len <= visible_rows) {
        scroll_offset.* = 0;
    } else {
        scroll_offset.* = @min(scroll_offset.*, @as(i32, @intCast(rows.items.len - visible_rows)));
        if (scroll_offset.* < 0) scroll_offset.* = 0;

        // Keep the proposal row on screen — it is the user's next
        // interaction (the keypress capture or Confirm/Cancel): clamp the
        // scroll so the proposal index sits inside the window. A no-op
        // when already visible; snaps to the nearest window edge when
        // not.
        if (add_edit != null) {
            const proposal_index: i32 = @intCast(add_insert_position);
            const lowest: i32 = @max(0, proposal_index - @as(i32, @intCast(visible_rows)) + 1);
            const highest: i32 = @min(proposal_index, @as(i32, @intCast(rows.items.len - visible_rows)));
            scroll_offset.* = @min(@max(scroll_offset.*, lowest), highest);
        }
    }
    const first_visible: usize = @intCast(scroll_offset.*);
    const last_visible = @min(rows.items.len, first_visible + visible_rows);

    // The edit phase targeting a given row (phase-specific rendering).
    const listening_index: ?usize = if (edit_state) |edit_source| switch (edit_source.edit) {
        .listening => |target| switch (target) {
            .binding => |index| index,
            else => null,
        },
        else => null,
    } else null;
    const pending_data: ?keybind_edit.PendingKeybind = if (edit_state) |edit_source| switch (edit_source.edit) {
        .pending => |pending| pending,
        else => null,
    } else null;

    for (rows.items[first_visible..last_visible], first_visible..) |row_entry, row_index| {
        const row_y = list_top + @as(i32, @intCast(row_index - first_visible)) * row_stride;
        switch (row_entry) {
            .add_edit => {
                // The add proposal row: the obvious listening panel (no
                // button — a click ANYWHERE is a mouse capture, handled by
                // the capture seam), or the pending proposal row.
                switch (add_edit.?) {
                    // An add never opens the picker (the standalone add's
                    // picker phase converts to listening on pick).
                    .picker => {},
                    .listening => |target| {
                        const label_text = try std.fmt.allocPrint(allocator, "Press a key for {s}… (Esc to cancel)", .{actionDisplayLabel(target.add)});
                        const panel_width = try emitKeybindPanel(elements, allocator, font_metrics, label_text, content_x, row_y, settings_row_height, button_color);
                        try emitListeningHighlight(elements, allocator, content_x, row_y, panel_width);
                    },
                    .pending => |pending| try emitPendingRow(elements, allocator, font_metrics, row_y, content_x, pending, bindings, button_color),
                }
            },
            .binding => |index| {
                const binding = bindings[index];
                const is_listening = listening_index == index;
                const is_pending = if (pending_data) |pending| pending.replace_index == index else false;

                if (is_listening) {
                    // The obvious listening state: highlighted panel (a
                    // button with NO command — a click is a mouse capture
                    // through the seam; the handler no-ops a payload-less
                    // command), the action panel kept for context.
                    const label_text = "Press a key… (Esc to cancel)";
                    const panel_width = try emitKeybindPanel(elements, allocator, font_metrics, label_text, content_x, row_y, settings_row_height, button_color);
                    try emitListeningHighlight(elements, allocator, content_x, row_y, panel_width);
                    const action_label = try actionPanelLabel(allocator, binding.action);
                    _ = try emitKeybindPanel(elements, allocator, font_metrics, action_label, content_x + panel_width + settings_row_gap, row_y, settings_row_height, button_color);
                    continue;
                }
                if (is_pending) {
                    try emitPendingRow(elements, allocator, font_metrics, row_y, content_x, pending_data.?, bindings, button_color);
                    continue;
                }

                // Normal row: combo panels + a rekey button over the combo,
                // the action panel + a reassign button over it, then X + +.
                var panel_x = content_x;
                const key_label = keyIdDisplayLabel(inputIdOf(binding.input));
                const modifiers = [_]?[]const u8{
                    if (binding.modifiers.ctrl) "Ctrl" else null,
                    if (binding.modifiers.shift) "Shift" else null,
                    if (binding.modifiers.alt) "Alt" else null,
                };
                for (modifiers) |modifier_label| {
                    if (modifier_label) |label| {
                        panel_x += try emitKeybindPanel(elements, allocator, font_metrics, label, panel_x, row_y, settings_row_height, button_color);
                        try elements.append(allocator, .{ .text_label = .{
                            .text = "+",
                            .screen_position = .{
                                .x = panel_x + @divTrunc(settings_row_gap - font_metrics.measureSpanWidth(text("+"), settings_row_font_size), 2),
                                .y = row_y + @divTrunc(settings_row_height - settings_row_font_size, 2),
                            },
                            .font_size = settings_row_font_size,
                            .blocks_input = false,
                        } });
                        panel_x += settings_row_gap;
                    }
                }
                panel_x += try emitKeybindPanel(elements, allocator, font_metrics, key_label, panel_x, row_y, settings_row_height, button_color);
                // Rekey: an invisible button over the whole combo zone.
                try elements.append(allocator, .{ .button = .{
                    .screen_position = .{ .x = content_x, .y = row_y },
                    .width = panel_x - content_x,
                    .height = settings_row_height,
                    .action = .edit_keybind,
                    .payload = .{ .keybind_command = .{ .rekey = index } },
                } });

                // Action panel (flush after the combo) + the reassign
                // button over it.
                const action_label = try actionPanelLabel(allocator, binding.action);
                const action_panel_width = try emitKeybindPanel(elements, allocator, font_metrics, action_label, panel_x, row_y, settings_row_height, button_color);
                try elements.append(allocator, .{ .button = .{
                    .screen_position = .{ .x = panel_x, .y = row_y },
                    .width = action_panel_width,
                    .height = settings_row_height,
                    .action = .edit_keybind,
                    .payload = .{ .keybind_command = .{ .reassign = index } },
                } });
                panel_x += action_panel_width + settings_row_gap;

                // X (remove — direct) + + (add a combo for this action).
                panel_x += try emitKeybindCommandPanel(elements, allocator, font_metrics, "X", panel_x, row_y, button_color, .{ .remove = index }, false, "Delete");
                panel_x += settings_row_gap;
                _ = try emitKeybindCommandPanel(elements, allocator, font_metrics, "+", panel_x, row_y, button_color, .{ .add = binding.action }, false, "Add another keybind");
            },
        }
    }

    // Scrollbar (only when the binding list overflows the window): track +
    // thumb at the left column's right edge (the screen midpoint).
    if (rows.items.len > visible_rows) {
        try emitScrollbar(
            elements,
            allocator,
            picker_x - @divTrunc(ui_gap, 2) - scrollbar_width,
            list_top,
            region_height,
            visible_rows,
            rows.items.len,
            scroll_offset.*,
        );
    }

    // The right-column action PICKER (the picker phase): the full
    // scrollable action list — every Action, bound or not, labeled
    // "Action — Contexts". Picking one either moves the target row's combo
    // to it (reassign) or starts the standalone add's listening.
    if (edit_state) |edit_source| switch (edit_source.edit) {
        .picker => |picker_target| {
            try elements.append(allocator, .{ .text_label = .{
                .text = "Pick an action (Esc to cancel)",
                .screen_position = .{ .x = picker_x, .y = content_top + @divTrunc(settings_row_height - settings_row_font_size, 2) },
                .font_size = settings_row_font_size,
                .blocks_input = false,
            } });
            const picker_list_top = content_top + row_stride;
            const picker_region_height = buttons_top - picker_list_top;
            const picker_visible_rows: usize = @intCast(@max(1, @divTrunc(picker_region_height, row_stride)));
            const actions = std.meta.tags(types.Action);
            if (actions.len <= picker_visible_rows) {
                picker_scroll_offset.* = 0;
            } else {
                picker_scroll_offset.* = @min(picker_scroll_offset.*, @as(i32, @intCast(actions.len - picker_visible_rows)));
                if (picker_scroll_offset.* < 0) picker_scroll_offset.* = 0;
            }
            const first: usize = @intCast(picker_scroll_offset.*);
            const last = @min(actions.len, first + picker_visible_rows);
            for (actions[first..last], first..) |action, action_index| {
                const action_y = picker_list_top + @as(i32, @intCast(action_index - first)) * row_stride;
                const label_text = try actionPanelLabel(allocator, action);
                // Highlight the reassign target's current action.
                const active = switch (picker_target) {
                    .binding => |index| index < bindings.len and bindings[index].action == action,
                    else => false,
                };
                _ = try emitKeybindCommandPanel(
                    elements,
                    allocator,
                    font_metrics,
                    label_text,
                    picker_x,
                    action_y,
                    button_color,
                    .{ .pick = action },
                    active,
                    null,
                );
            }

            // Scrollbar (only when the action list overflows the window):
            // track + thumb at the content right edge.
            if (actions.len > picker_visible_rows) {
                try emitScrollbar(
                    elements,
                    allocator,
                    screen.x + screen.width - settings_padding - scrollbar_width,
                    picker_list_top,
                    picker_region_height,
                    picker_visible_rows,
                    actions.len,
                    picker_scroll_offset.*,
                );
            }
        },
        else => {},
    };
}

/// A binding's input id, whatever variant it is.
fn inputIdOf(input: types.RawInput) []const u8 {
    return switch (input) {
        .key => |id| id,
        .mouse_button => |id| id,
        .gamepad_button => |id| id,
    };
}

/// Sort display order by action (declaration order) over INDICES (so each
/// row carries its original binding index for edit targeting). Stable.
fn bindingIndexActionLessThan(
    bindings: []const types.InputBinding,
    left: usize,
    right: usize,
) bool {
    return @intFromEnum(bindings[left].action) < @intFromEnum(bindings[right].action);
}

/// "Action — Contexts" (the derived context set) — the action panel + picker
/// row label.
fn actionPanelLabel(allocator: std.mem.Allocator, action: types.Action) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} — {s}", .{
        actionDisplayLabel(action),
        contextSetDisplayLabel(types.actionBindingContexts(action)),
    });
}

/// Panel + centered label (returns the panel width — the caller places the
/// next panel flush after it). Never narrower than `keybind_min_panel_width`
/// (9-slice panels render badly small).
fn emitKeybindPanel(
    elems: *UiElementList,
    alloc: std.mem.Allocator,
    fm: FontMetrics,
    label_text: []const u8,
    panel_x: i32,
    panel_y: i32,
    panel_height: i32,
    panel_color: Color,
) !i32 {
    const label_width = fm.measureSpanWidth(text(label_text), settings_row_font_size);
    const panel_width = @max(
        label_width + 2 * keybind_panel_padding,
        keybind_min_panel_width,
    );
    try elems.append(alloc, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = .{ .x = panel_x, .y = panel_y },
        .width = panel_width,
        .height = panel_height,
        .color = panel_color,
    } });
    try elems.append(alloc, .{ .text_label = .{
        .text = label_text,
        .screen_position = .{
            .x = panel_x + @divTrunc(panel_width - label_width, 2),
            .y = panel_y + @divTrunc(panel_height - settings_row_font_size, 2),
        },
        .font_size = settings_row_font_size,
        .blocks_input = false,
    } });
    return panel_width;
}

/// Panel + centered label + an invisible button carrying a `.edit_keybind`
/// command (the interactive panel shape; optional hover tooltip). Returns
/// the panel width.
fn emitKeybindCommandPanel(
    elems: *UiElementList,
    alloc: std.mem.Allocator,
    fm: FontMetrics,
    label_text: []const u8,
    panel_x: i32,
    panel_y: i32,
    panel_color: Color,
    command: types.KeybindCommand,
    highlighted: bool,
    tooltip_text: ?[]const u8,
) !i32 {
    const label_width = fm.measureSpanWidth(text(label_text), settings_row_font_size);
    const panel_width = @max(
        label_width + 2 * keybind_panel_padding,
        keybind_min_panel_width,
    );
    try elems.append(alloc, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = .{ .x = panel_x, .y = panel_y },
        .width = panel_width,
        .height = settings_row_height,
        .color = panel_color,
    } });
    try elems.append(alloc, .{ .button = .{
        .screen_position = .{ .x = panel_x, .y = panel_y },
        .width = panel_width,
        .height = settings_row_height,
        .action = .edit_keybind,
        .payload = .{ .keybind_command = command },
        .highlighted = highlighted,
        .tooltip = if (tooltip_text) |tooltip_label| .{ .header = try spanRow(alloc, text(tooltip_label)) } else null,
    } });
    try elems.append(alloc, .{ .text_label = .{
        .text = label_text,
        .screen_position = .{
            .x = panel_x + @divTrunc(panel_width - label_width, 2),
            .y = panel_y + @divTrunc(settings_row_height - settings_row_font_size, 2),
        },
        .font_size = settings_row_font_size,
        .blocks_input = false,
    } });
    return panel_width;
}

/// The listening panel's highlight outline: a `highlighted` button with NO
/// command (a click during listening is a mouse capture through the seam;
/// the handler no-ops a payload-less `.edit_keybind`).
fn emitListeningHighlight(
    elems: *UiElementList,
    alloc: std.mem.Allocator,
    panel_x: i32,
    panel_y: i32,
    panel_width: i32,
) !void {
    try elems.append(alloc, .{ .button = .{
        .screen_position = .{ .x = panel_x, .y = panel_y },
        .width = panel_width,
        .height = settings_row_height,
        .action = .edit_keybind,
        .highlighted = true,
    } });
}

/// A pending proposal row: the captured combo panels + the proposal's
/// action panel + Confirm / Cancel buttons + the steal warning (warn color).
fn emitPendingRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    row_y: i32,
    content_x: i32,
    pending: keybind_edit.PendingKeybind,
    bindings: []const types.InputBinding,
    button_color: Color,
) !void {
    var panel_x = content_x;
    const key_label = keyIdDisplayLabel(inputIdOf(pending.binding.input));
    const modifiers = [_]?[]const u8{
        if (pending.binding.modifiers.ctrl) "Ctrl" else null,
        if (pending.binding.modifiers.shift) "Shift" else null,
        if (pending.binding.modifiers.alt) "Alt" else null,
    };
    for (modifiers) |modifier_label| {
        if (modifier_label) |label| {
            panel_x += try emitKeybindPanel(elements, allocator, font_metrics, label, panel_x, row_y, settings_row_height, button_color);
            try elements.append(allocator, .{ .text_label = .{
                .text = "+",
                .screen_position = .{
                    .x = panel_x + @divTrunc(settings_row_gap - font_metrics.measureSpanWidth(text("+"), settings_row_font_size), 2),
                    .y = row_y + @divTrunc(settings_row_height - settings_row_font_size, 2),
                },
                .font_size = settings_row_font_size,
                .blocks_input = false,
            } });
            panel_x += settings_row_gap;
        }
    }
    panel_x += try emitKeybindPanel(elements, allocator, font_metrics, key_label, panel_x, row_y, settings_row_height, button_color);

    // The proposal's action panel.
    const action_label = try actionPanelLabel(allocator, pending.binding.action);
    panel_x += try emitKeybindPanel(elements, allocator, font_metrics, action_label, panel_x, row_y, settings_row_height, button_color);
    panel_x += settings_row_gap;

    // Confirm / Cancel. Enter CONFIRMS through the capture seam during
    // pending (the modal-capture-state convention — safe because capture
    // happens during listening; Escape cancels the same way).
    panel_x += try emitKeybindCommandPanel(elements, allocator, font_metrics, "Confirm", panel_x, row_y, button_color, .confirm, true, null);
    panel_x += settings_row_gap;
    panel_x += try emitKeybindCommandPanel(elements, allocator, font_metrics, "Cancel", panel_x, row_y, button_color, .cancel, false, null);

    // The steal warning (see findKeybindSteal): the combo currently fires
    // another binding — confirming REMOVES it — or duplicates its own
    // action's combo (confirming dedupes).
    if (pending.stolen_index) |stolen_index| {
        const stolen = bindings[stolen_index];
        const warning_text = if (stolen.action == pending.binding.action)
            try std.fmt.allocPrint(allocator, "This combo is already bound to {s} — confirming removes the duplicate", .{actionDisplayLabel(stolen.action)})
        else
            try std.fmt.allocPrint(allocator, "This combo currently fires {s} ({s}) — confirming will remove it", .{
                actionDisplayLabel(stolen.action),
                contextSetDisplayLabel(types.actionBindingContexts(stolen.action)),
            });
        try elements.append(allocator, .{ .text_label = .{
            .text = warning_text,
            .screen_position = .{
                .x = panel_x + settings_row_gap,
                .y = row_y + @divTrunc(settings_row_height - settings_row_font_size, 2),
            },
            .font_size = settings_row_font_size,
            .color = negative_color,
            .blocks_input = false,
        } });
    }
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

test "buildEditorBrowser: tabs, rows carry payloads + actions, window + clamp" {
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

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
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

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
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
    // (derived expectations — a new editor kind can't appear as a tab
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

test "buildOptionsMenu: Revalidate Mission is editor-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Editor screen: the button is present (bottom of the editor block,
    // under New Mission).
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .editor, null, button_color, null);
        var found = false;
        for (elements.items) |element| switch (element) {
            .button => |b| {
                if (b.action == .revalidate_editor_mission) found = true;
            },
            else => {},
        };
        try std.testing.expect(found);
    }

    // Level screen: absent (the button only renders for the editor).
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .level, null, button_color, null);
        for (elements.items) |element| switch (element) {
            .button => |b| {
                try std.testing.expect(b.action != .revalidate_editor_mission);
            },
            else => {},
        };
    }
}

test "buildOptionsMenu: the main-menu variant carries the meta entries, not the session verbs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    var elements: UiElementList = .empty;
    try buildOptionsMenu(&elements, allocator, metrics, screen, .main_menu, null, button_color, null);
    // The main-menu variant: Settings + Credits + Exit Game (tests run
    // native — the web build omits Exit Game), and none of the session
    // verbs, the editor block, or Exit to Main Menu. No Continue — like
    // every variant, the menu has no close button (Escape + the top-bar
    // options button close it).
    for ([_]types.Action{ .open_settings, .open_credits, .exit_game }) |expected| {
        var found = false;
        for (elements.items) |element| switch (element) {
            .button => |b| {
                if (b.action == expected) found = true;
            },
            else => {},
        };
        try std.testing.expect(found);
    }
    for ([_]types.Action{
        .restart_mission,     .exit_mission,       .exit_to_menu,              .save_game,
        .save_editor_mission, .new_editor_mission, .revalidate_editor_mission, .escape,
    }) |forbidden| {
        for (elements.items) |element| switch (element) {
            .button => |b| try std.testing.expect(b.action != forbidden),
            else => {},
        };
    }
}

test "buildMainMenu: session verbs + mode entries only; Settings/Credits live in the options menu" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Continue present only when a game exists to resume.
    {
        var elements: UiElementList = .empty;
        try buildMainMenu(&elements, allocator, metrics, screen, true, null, button_color);
        var found_continue = false;
        for (elements.items) |element| switch (element) {
            .button => |b| {
                if (b.action == .continue_game) found_continue = true;
            },
            else => {},
        };
        try std.testing.expect(found_continue);
    }
    {
        var elements: UiElementList = .empty;
        try buildMainMenu(&elements, allocator, metrics, screen, false, null, button_color);
        for (elements.items) |element| switch (element) {
            .button => |b| try std.testing.expect(b.action != .continue_game),
            else => {},
        };
    }

    // Both cases: New Game / Load Save / Editor present; Settings +
    // Credits moved to the options menu (the top-bar options button is
    // the entry point from every screen).
    var elements: UiElementList = .empty;
    try buildMainMenu(&elements, allocator, metrics, screen, true, null, button_color);
    for ([_]types.Action{ .new_game, .toggle_load_save_menu, .toggle_editor_browser }) |expected| {
        var found = false;
        for (elements.items) |element| switch (element) {
            .button => |b| {
                if (b.action == expected) found = true;
            },
            else => {},
        };
        try std.testing.expect(found);
    }
    for ([_]types.Action{ .open_settings, .open_credits }) |moved| {
        for (elements.items) |element| switch (element) {
            .button => |b| try std.testing.expect(b.action != moved),
            else => {},
        };
    }
}

test "buildMainMenu: Import Game + the web storage disclaimer are web only (the null persistent dir path)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Web (the null persistent-dir-path signal): the Import Game button is
    // present (with a tooltip) + the storage disclaimer is present above
    // the title (both lines of the chosen wording — DESIGN → Web storage
    // model).
    {
        var elements: UiElementList = .empty;
        try buildMainMenu(&elements, allocator, metrics, screen, true, null, button_color);
        var import_button: ?Button = null;
        var found_disclaimer_header = false;
        var found_disclaimer_body = false;
        for (elements.items) |element| switch (element) {
            .button => |b| {
                if (b.action == .import_game) import_button = b;
            },
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "WEB DISCLAIMER:")) found_disclaimer_header = true;
                if (std.mem.indexOf(u8, label.text, "does not persist between sessions") != null)
                    found_disclaimer_body = true;
            },
            else => {},
        };
        const found = import_button orelse @panic("no Import Game button on web");
        try std.testing.expect(found.tooltip != null);
        try std.testing.expect(found_disclaimer_header);
        try std.testing.expect(found_disclaimer_body);
    }

    // Native (a real persistent dir path): no button, no disclaimer.
    {
        var elements: UiElementList = .empty;
        try buildMainMenu(&elements, allocator, metrics, screen, true, "zig-cache/fake-persistent-dir", button_color);
        for (elements.items) |element| switch (element) {
            .button => |b| try std.testing.expect(b.action != .import_game),
            .text_label => |label| try std.testing.expect(
                std.mem.indexOf(u8, label.text, "WEB DISCLAIMER:") == null,
            ),
            else => {},
        };
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
    // the mission being edited). Settings + Exit to Main Menu remain —
    // and no close button, per the no-Continue convention.
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

test "buildOptionsMenu: Export Game on every variant, web only (null persistent dir path)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Web (null path): present on EVERY variant with the ziglop.zip
    // tooltip + label — the options menu is the only menu surface
    // reachable mid-level, so in-session backups are always possible.
    for ([_]state.Screen{ .main_menu, .level, .hub, .editor }) |variant| {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, variant, null, button_color, null);
        const button = (for (elements.items) |element| switch (element) {
            .button => |b| if (b.action == .export_game) break b,
            else => {},
        } else @panic("no Export Game button"));
        const tooltip = button.tooltip orelse @panic("Export Game button has no tooltip");
        try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
        try std.testing.expectEqualStrings(
            "Downloads ziglop.zip — your full game folder (settings, saves, custom missions)",
            tooltip.body[0][0].text,
        );
        var label_seen = false;
        for (elements.items) |element| switch (element) {
            .text_label => |label| if (std.mem.eql(u8, label.text, "Export Game")) {
                label_seen = true;
            },
            else => {},
        };
        try std.testing.expect(label_seen);
    }

    // Native (a path): no button at all — the real persistent dir IS the
    // game folder.
    for ([_]state.Screen{ .main_menu, .level, .hub, .editor }) |variant| {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, variant, null, button_color, "/home/tester/.ziglop");
        for (elements.items) |element| switch (element) {
            .button => |b| try std.testing.expect(b.action != .export_game),
            else => {},
        };
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

test "buildSettingsPanel: tab row on both tabs; settings tab keeps control rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const bindings = [_]types.InputBinding{
        .{ .input = .{ .key = "KeyZ" }, .modifiers = .{ .ctrl = true }, .action = .undo },
    };
    const settings: types.Settings = .{ .input_bindings = &bindings };

    var scroll: i32 = 0;
    var picker_scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildSettingsPanel(&elements, allocator, metrics, screen, settings, undefined, .{ .r = 50, .g = 50, .b = 50 }, .settings, &scroll, null, &picker_scroll);

    // The tab row is tab-independent chrome: both tab buttons, the active
    // one highlighted, regardless of which tab is showing.
    var found_settings_tab_button = false;
    var found_keybinds_tab_button = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_settings_tab) {
            switch (button.payload.?.settings_tab) {
                .settings => {
                    found_settings_tab_button = true;
                    try std.testing.expect(button.highlighted);
                },
                .keybinds => {
                    found_keybinds_tab_button = true;
                    try std.testing.expect(!button.highlighted);
                },
            }
        },
        else => {},
    };
    try std.testing.expect(found_settings_tab_button);
    try std.testing.expect(found_keybinds_tab_button);

    // The Settings tab keeps its control rows (a settings toggle button),
    // and the control column still FITS: the tab row shrank the rows region,
    // and the rows-centering formula can silently overflow once the region
    // is tighter — the lowest control's bottom must clear the Back button's
    // top (the Back button toggles via the same .open_settings action that
    // opened the screen).
    var found_control = false;
    var lowest_control_bottom: i32 = 0;
    var back_button_top: i32 = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.action == .change_setting) {
                found_control = true;
                lowest_control_bottom = @max(
                    lowest_control_bottom,
                    button.screen_position.y + button.height,
                );
            }
            if (button.action == .open_settings) {
                back_button_top = button.screen_position.y;
            }
        },
        else => {},
    };
    try std.testing.expect(found_control);
    try std.testing.expect(back_button_top > 0);
    try std.testing.expect(lowest_control_bottom <= back_button_top);

    // Reset to Defaults, bottom-right on BOTH tabs: command-carrying button
    // + label + tooltip, mirroring the Back button's metrics (same row as
    // Back, mirrored x).
    var reset_button_seen = false;
    var reset_button_y: i32 = 0;
    var reset_label_seen = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .edit_keybind) {
            switch (button.payload.?.keybind_command) {
                .reset_defaults => {
                    reset_button_seen = true;
                    reset_button_y = button.screen_position.y;
                    try std.testing.expectEqual(
                        screen.x + screen.width - settings_padding - settings_button_width,
                        button.screen_position.x,
                    );
                    try std.testing.expectEqualStrings(
                        "Creates a backup of current settings and loads defaults",
                        button.tooltip.?.header.?[0].text,
                    );
                },
                else => {},
            }
        },
        .text_label => |label| if (std.mem.eql(u8, label.text, "Reset to Defaults")) {
            reset_label_seen = true;
        },
        else => {},
    };
    try std.testing.expect(reset_button_seen);
    try std.testing.expect(reset_label_seen);
    try std.testing.expectEqual(back_button_top, reset_button_y);
}

test "buildSettingsPanel: keybinds tab — rows, key panels, action labels + context tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    // Two combos on ONE action (undo: ctrl+Z and U — adjacent rows, no
    // group headers), plus cross-context same-combo-style rows with their
    // derived context tags.
    const bindings = [_]types.InputBinding{
        .{ .input = .{ .key = "KeyZ" }, .modifiers = .{ .ctrl = true }, .action = .undo },
        .{ .input = .{ .key = "KeyU" }, .action = .undo },
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Digit1" }, .action = .select_editor_tool },
    };
    const settings: types.Settings = .{ .input_bindings = &bindings };

    var scroll: i32 = 0;
    var picker_scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildSettingsPanel(&elements, allocator, metrics, screen, settings, undefined, .{ .r = 50, .g = 50, .b = 50 }, .keybinds, &scroll, null, &picker_scroll);

    // NO group headers: the action name rides in every row's action panel,
    // so no exact-match action-name label exists (the "Undo" spelling only
    // appears inside "Undo — Anytime" action labels).
    var undo_headers: usize = 0;
    var ctrl_labels: usize = 0;
    var z_labels: usize = 0;
    var u_labels: usize = 0;
    var plus_labels: usize = 0;
    var undo_anytime: usize = 0;
    var confirm_game: usize = 0;
    var select_tool_editor: usize = 0;
    for (elements.items) |element| switch (element) {
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Undo")) undo_headers += 1;
            if (std.mem.eql(u8, label.text, "Ctrl")) ctrl_labels += 1;
            if (std.mem.eql(u8, label.text, "Z")) z_labels += 1;
            if (std.mem.eql(u8, label.text, "U")) u_labels += 1;
            if (std.mem.eql(u8, label.text, "+")) plus_labels += 1;
            if (std.mem.eql(u8, label.text, "Undo — Anytime")) undo_anytime += 1;
            if (std.mem.eql(u8, label.text, "Confirm — Game")) confirm_game += 1;
            if (std.mem.eql(u8, label.text, "Select editor tool — Editor")) select_tool_editor += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 0), undo_headers);
    try std.testing.expectEqual(@as(usize, 1), ctrl_labels);
    try std.testing.expectEqual(@as(usize, 1), z_labels);
    try std.testing.expectEqual(@as(usize, 1), u_labels);
    // "+" appears as BOTH the combo separator (ctrl + Z) and each row's
    // add-combo button label — at least the separator here.
    try std.testing.expect(plus_labels >= 1);

    // The editing chrome: each of the 4 rows carries a rekey button (over
    // its combo), a reassign button (over its action panel), an X (remove)
    // and a + (add a combo for its action); plus the standalone Add button.
    var rekey_buttons: usize = 0;
    var reassign_buttons: usize = 0;
    var remove_buttons: usize = 0;
    var add_buttons: usize = 0;
    var add_open_buttons: usize = 0;
    var reset_buttons: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .edit_keybind) {
            switch (button.payload.?.keybind_command) {
                .rekey => rekey_buttons += 1,
                .reassign => reassign_buttons += 1,
                .remove => remove_buttons += 1,
                .add => add_buttons += 1,
                .add_open => add_open_buttons += 1,
                .reset_defaults => reset_buttons += 1,
                else => {},
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), rekey_buttons);
    try std.testing.expectEqual(@as(usize, 4), reassign_buttons);
    try std.testing.expectEqual(@as(usize, 4), remove_buttons);
    try std.testing.expectEqual(@as(usize, 4), add_buttons);
    try std.testing.expectEqual(@as(usize, 1), add_open_buttons);
    // The bottom-right Reset to Defaults button shows on the keybinds tab
    // too (both tabs).
    try std.testing.expectEqual(@as(usize, 1), reset_buttons);

    // The X/+ tooltips: every remove button's tooltip says Delete, every
    // add button's says Add another keybind (header-only tooltips).
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .edit_keybind) {
            switch (button.payload.?.keybind_command) {
                .remove => try std.testing.expectEqualStrings("Delete", button.tooltip.?.header.?[0].text),
                .add => try std.testing.expectEqualStrings("Add another keybind", button.tooltip.?.header.?[0].text),
                else => {},
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), undo_anytime); // both combos
    // The min-width contract: every keybind panel (key/modifier/action —
    // all settings_row_height) stays at or above `keybind_min_panel_width`
    // (9-slice panels render badly below it; single-char keys would stub).
    for (elements.items) |element| switch (element) {
        .nine_slice_panel => |panel| {
            if (panel.height == settings_row_height) {
                try std.testing.expect(panel.width >= keybind_min_panel_width);
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), confirm_game);
    try std.testing.expectEqual(@as(usize, 1), select_tool_editor);
}

test "buildSettingsPanel: keybinds tab add proposal — below its action's group, kept on screen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const row_stride = settings_row_height + settings_row_gap;
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // A row's `+` (an add listening on an EXISTING action): the proposal
    // renders directly below that action's row group — one row_stride
    // under the group's last row's action label.
    {
        const bindings = [_]types.InputBinding{
            .{ .input = .{ .key = "KeyZ" }, .modifiers = .{ .ctrl = true }, .action = .undo },
            .{ .input = .{ .key = "Enter" }, .action = .confirm },
        };
        const settings: types.Settings = .{ .input_bindings = &bindings };
        var edit_state: keybind_edit.KeybindEditState = .{ .edit = .{ .listening = .{ .add = .undo } } };
        var scroll: i32 = 0;
        var picker_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildSettingsPanel(&elements, allocator, metrics, screen, settings, undefined, button_color, .keybinds, &scroll, &edit_state, &picker_scroll);

        var undo_label_y: i32 = -1;
        var confirm_label_y: i32 = -1;
        var proposal_y: i32 = -1;
        const proposal_text = try std.fmt.allocPrint(allocator, "Press a key for {s}… (Esc to cancel)", .{actionDisplayLabel(.undo)});
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "Undo — Anytime")) undo_label_y = label.screen_position.y;
                if (std.mem.eql(u8, label.text, "Confirm — Game")) confirm_label_y = label.screen_position.y;
                if (std.mem.eql(u8, label.text, proposal_text)) proposal_y = label.screen_position.y;
            },
            else => {},
        };
        try std.testing.expect(undo_label_y >= 0);
        try std.testing.expect(confirm_label_y >= 0);
        try std.testing.expect(proposal_y >= 0);
        // Undo is the first display row; the proposal is its row + 1.
        try std.testing.expectEqual(undo_label_y + row_stride, proposal_y);
        // And it sits above the next action's group (undo < confirm in
        // display order).
        try std.testing.expect(proposal_y < confirm_label_y);
    }

    // A standalone add of a FRESH action (no bindings for it): the
    // proposal renders at the top, pushing the first row down one.
    {
        const bindings = [_]types.InputBinding{
            .{ .input = .{ .key = "KeyZ" }, .modifiers = .{ .ctrl = true }, .action = .undo },
        };
        const settings: types.Settings = .{ .input_bindings = &bindings };
        var edit_state: keybind_edit.KeybindEditState = .{ .edit = .{ .listening = .{ .add = .dump_event_log } } };
        var scroll: i32 = 0;
        var picker_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildSettingsPanel(&elements, allocator, metrics, screen, settings, undefined, button_color, .keybinds, &scroll, &edit_state, &picker_scroll);

        var undo_label_y: i32 = -1;
        var proposal_y: i32 = -1;
        const proposal_text = try std.fmt.allocPrint(allocator, "Press a key for {s}… (Esc to cancel)", .{actionDisplayLabel(.dump_event_log)});
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "Undo — Anytime")) undo_label_y = label.screen_position.y;
                if (std.mem.eql(u8, label.text, proposal_text)) proposal_y = label.screen_position.y;
            },
            else => {},
        };
        try std.testing.expect(undo_label_y >= 0);
        try std.testing.expect(proposal_y >= 0);
        try std.testing.expectEqual(proposal_y + row_stride, undo_label_y);
    }

    // Kept on screen: 60 rows overflow; scrolled to the bottom WITHOUT
    // an edit first (the view's own clamp is the oracle for the pre-bump
    // scroll value), then the same scroll WITH a row-`+` proposal on the
    // last display action — the proposal would land beyond the window,
    // so the scroll bumps one notch and the proposal is emitted.
    {
        const action_tags = std.meta.tags(types.Action);
        var long_bindings: [60]types.InputBinding = undefined;
        for (&long_bindings, action_tags[0..60], 0..) |*binding, action, index| {
            binding.* = .{
                .input = .{ .key = if (index % 2 == 0) "Enter" else "Space" },
                .action = action,
            };
        }
        const long_settings: types.Settings = .{ .input_bindings = &long_bindings };

        var scroll: i32 = 999;
        var picker_scroll: i32 = 0;
        var base_elements: UiElementList = .empty;
        try buildSettingsPanel(&base_elements, allocator, metrics, screen, long_settings, undefined, button_color, .keybinds, &scroll, null, &picker_scroll);
        try std.testing.expect(scroll > 0); // clamped to the bottom (60 rows)
        const bottom_scroll = scroll;

        var edit_state: keybind_edit.KeybindEditState = .{ .edit = .{ .listening = .{ .add = action_tags[59] } } };
        var elements: UiElementList = .empty;
        try buildSettingsPanel(&elements, allocator, metrics, screen, long_settings, undefined, button_color, .keybinds, &scroll, &edit_state, &picker_scroll);
        try std.testing.expectEqual(bottom_scroll + 1, scroll);

        const proposal_text = try std.fmt.allocPrint(allocator, "Press a key for {s}… (Esc to cancel)", .{actionDisplayLabel(action_tags[59])});
        var proposal_seen = false;
        for (elements.items) |element| switch (element) {
            .text_label => |label| if (std.mem.eql(u8, label.text, proposal_text)) {
                proposal_seen = true;
            },
            else => {},
        };
        try std.testing.expect(proposal_seen);
    }
}

test "buildSettingsPanel: keybinds tab scroll window + clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    // 60 distinct actions — enough rows (headers + combos) to overflow any
    // plausible window. Every combo on the same key: the list is display-only
    // here (no conflict scan on the view path).
    const action_tags = std.meta.tags(types.Action);
    var bindings: [60]types.InputBinding = undefined;
    for (&bindings, action_tags[0..60], 0..) |*binding, action, index| {
        binding.* = .{
            .input = .{ .key = if (index % 2 == 0) "Enter" else "Space" },
            .action = action,
        };
    }
    const settings: types.Settings = .{ .input_bindings = &bindings };

    // No overflow (short list): a forced-huge scroll clamps to 0.
    {
        const short: types.Settings = .{ .input_bindings = bindings[0..3] };
        var scroll: i32 = 999;
        var picker_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildSettingsPanel(&elements, allocator, metrics, screen, short, undefined, .{ .r = 50, .g = 50, .b = 50 }, .keybinds, &scroll, null, &picker_scroll);
        try std.testing.expectEqual(@as(i32, 0), scroll);
    }

    // Overflow: scroll 999 clamps to the last full window (>= 1), and only
    // the visible window's rows are emitted (fewer action labels than
    // bindings).
    var scroll: i32 = 999;
    var picker_scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildSettingsPanel(&elements, allocator, metrics, screen, settings, undefined, .{ .r = 50, .g = 50, .b = 50 }, .keybinds, &scroll, null, &picker_scroll);
    try std.testing.expect(scroll > 0);
    var emitted_rows: usize = 0;
    for (elements.items) |element| switch (element) {
        .nine_slice_panel => |panel| if (panel.height == settings_row_height) {
            emitted_rows += 1;
        },
        else => {},
    };
    try std.testing.expect(emitted_rows > 0);
    try std.testing.expect(emitted_rows < bindings.len);

    // The window is the same size at the top and the end (a full window at
    // every offset — whole visible rows only).
    var top_scroll: i32 = 0;
    var top_picker_scroll: i32 = 0;
    var top_elements: UiElementList = .empty;
    try buildSettingsPanel(&top_elements, allocator, metrics, screen, settings, undefined, .{ .r = 50, .g = 50, .b = 50 }, .keybinds, &top_scroll, null, &top_picker_scroll);
    var top_rows: usize = 0;
    for (top_elements.items) |element| switch (element) {
        .nine_slice_panel => |panel| if (panel.height == settings_row_height) {
            top_rows += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(emitted_rows, top_rows);

    // Negative scroll clamps to 0.
    scroll = -5;
    var elements_neg: UiElementList = .empty;
    try buildSettingsPanel(&elements_neg, allocator, metrics, screen, settings, undefined, .{ .r = 50, .g = 50, .b = 50 }, .keybinds, &scroll, null, &picker_scroll);
    try std.testing.expectEqual(@as(i32, 0), scroll);
}

test "buildSettingsPanel: keybinds tab scrollbars — track + thumb per overflowing column, none when content fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    // 60 distinct actions — enough rows to overflow either column's window
    // on this screen.
    const action_tags = std.meta.tags(types.Action);
    var bindings: [60]types.InputBinding = undefined;
    for (&bindings, action_tags[0..60], 0..) |*binding, action, index| {
        binding.* = .{
            .input = .{ .key = if (index % 2 == 0) "Enter" else "Space" },
            .action = action,
        };
    }
    const settings: types.Settings = .{ .input_bindings = &bindings };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Short list, picker closed: nothing overflows, no scrollbar rects.
    {
        const short: types.Settings = .{ .input_bindings = bindings[0..3] };
        var scroll: i32 = 0;
        var picker_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildSettingsPanel(&elements, allocator, metrics, screen, short, undefined, button_color, .keybinds, &scroll, null, &picker_scroll);
        var scrollbar_rects: usize = 0;
        for (elements.items) |element| switch (element) {
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, ui_element.scrollbar_track_color) or
                    std.meta.eql(rect.color, ui_element.scrollbar_thumb_color)) scrollbar_rects += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 0), scrollbar_rects);
    }

    // Overflowing list, picker closed: exactly one track + one thumb; the
    // track flush to the left column's right edge (the screen midpoint);
    // the thumb at the track's top at scroll 0, below it at the clamped
    // max, always inside the track, never shorter than the min thumb.
    {
        var scroll: i32 = 0;
        var picker_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildSettingsPanel(&elements, allocator, metrics, screen, settings, undefined, button_color, .keybinds, &scroll, null, &picker_scroll);
        var track_x: i32 = -1;
        var track_y: i32 = -1;
        var track_height: i32 = -1;
        var scrollbar_rects: usize = 0;
        var thumb_y: i32 = -1;
        var thumb_height: i32 = -1;
        for (elements.items) |element| switch (element) {
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, ui_element.scrollbar_track_color)) {
                    track_x = rect.screen_position.x;
                    track_y = rect.screen_position.y;
                    track_height = rect.height;
                    scrollbar_rects += 1;
                } else if (std.meta.eql(rect.color, ui_element.scrollbar_thumb_color)) {
                    thumb_y = rect.screen_position.y;
                    thumb_height = rect.height;
                    scrollbar_rects += 1;
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), scrollbar_rects);
        try std.testing.expectEqual(
            screen.x + @divTrunc(screen.width, 2) - scrollbar_width,
            track_x,
        );
        try std.testing.expectEqual(track_y, thumb_y);
        try std.testing.expect(thumb_height >= ui_element.scrollbar_thumb_min_height);
        // The thumb represents the visible SLICE: strictly smaller than the
        // track whenever the content overflows it.
        try std.testing.expect(thumb_height < track_height);

        // Max scroll (clamped by the builder): the thumb moves down and
        // stays inside the track.
        scroll = 999;
        var elements_max: UiElementList = .empty;
        try buildSettingsPanel(&elements_max, allocator, metrics, screen, settings, undefined, button_color, .keybinds, &scroll, null, &picker_scroll);
        var max_thumb_y: i32 = -1;
        var max_thumb_height: i32 = -1;
        for (elements_max.items) |element| switch (element) {
            .solid_rect => |rect| if (std.meta.eql(rect.color, ui_element.scrollbar_thumb_color)) {
                max_thumb_y = rect.screen_position.y;
                max_thumb_height = rect.height;
            },
            else => {},
        };
        try std.testing.expect(max_thumb_y > track_y);
        try std.testing.expect(max_thumb_y + max_thumb_height <= track_y + track_height);
    }

    // Picker open: BOTH columns overflow — the picker's track flush to the
    // content right edge joins the list's at the midpoint (4 rects).
    {
        var edit_state: keybind_edit.KeybindEditState = .{ .edit = .{ .picker = .{ .binding = 0 } } };
        var scroll: i32 = 0;
        var picker_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildSettingsPanel(&elements, allocator, metrics, screen, settings, undefined, button_color, .keybinds, &scroll, &edit_state, &picker_scroll);
        var scrollbar_rects: usize = 0;
        var right_edge_track_seen = false;
        for (elements.items) |element| switch (element) {
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, ui_element.scrollbar_track_color)) {
                    scrollbar_rects += 1;
                    if (rect.screen_position.x == screen.x + screen.width - settings_padding - scrollbar_width) {
                        right_edge_track_seen = true;
                    }
                } else if (std.meta.eql(rect.color, ui_element.scrollbar_thumb_color)) {
                    scrollbar_rects += 1;
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 4), scrollbar_rects);
        try std.testing.expect(right_edge_track_seen);
    }
}
