//! The main menu: the title screen's button stack + the web-only storage
//! disclaimer + version stamp (DESIGN → UI Framework). One of menus.zig's
//! per-surface splits.

const std = @import("std");
const types = @import("../types.zig");
const build_info = @import("build_info");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const ui_tooltip = @import("tooltip.zig");

const Action = types.Action;
const Rectangle = types.Rectangle;
const Color = types.Color;
const text = ui_element.text;
const FontMetrics = ui_element.FontMetrics;
const UiElementList = ui_element.UiElementList;
const emitPanelButton = emit.emitPanelButton;
const Tooltip = ui_element.Tooltip;
const TooltipRow = ui_element.TooltipRow;
const Button = ui_element.Button;
const rowWidth = ui_element.rowWidth;
const ui_gap = ui_element.ui_gap;
const panel_button_height = ui_element.panel_button_height;
const menu_button_width = ui_element.menu_button_width;
const menu_button_font_size = ui_element.menu_button_font_size;
const main_menu_title_font_size = ui_element.main_menu_title_font_size;
const main_menu_title_gap = ui_element.main_menu_title_gap;
const spanRow = ui_tooltip.spanRow;

/// Build the main-menu button stack: fixed-size buttons centered as a group
/// on `screen`, spaced by `ui_gap`, each with a centered text label. The
/// Continue button is emitted only when `continue_available` (there is a game
/// to resume - populated PlayerData). Settings + Credits live in the
/// OPTIONS MENU's main-menu variant (reached via the top-bar options
/// button / Escape - one convention from every screen); this stack holds
/// only the session-flow verbs + mode entries.
/// The web storage disclaimer's font + line gap (main menu, web only - see
/// DESIGN → File System & IO → Web storage model): centered lines above
/// the title, ONE font size for all of them. 60px is the smallest size
/// that keeps the standard 8px outline inside the SDF atlas's encodable
/// range (at 44px the outline clamps and the text reads noisy - see
/// DESIGN → Platform Seam → SDF text outline). Band heights are the font
/// sizes (the title's convention - the labels are single-line). The
/// disclaimer lines and the title all draw OUTLINED (the standard text
/// outline): the disclaimer sits over the menu background and read
/// poorly without it.
const main_menu_disclaimer_font_size: i32 = 60;
const main_menu_disclaimer_gap: i32 = 24;
/// The disclaimer wording (the chosen wording - DESIGN → File System & IO
/// → Web storage model), one line per entry, emitted in order. File scope
/// so the web-only test walks the SAME list (no duplicated strings to
/// drift). The long import/export sentence breaks at its phrase boundary
/// so no line spans wider than ~1600px of the 3840px reference (measured
/// against the font's advances - unbroken it would span 2956px, 77% of
/// the screen).
const disclaimer_lines = [_][]const u8{
    "WEB DISCLAIMER:",
    "Your saved data does not persist between sessions on web.",
    "Use the Import Game and Export Game functionality",
    "to load and save data for cross-session usage.",
};
/// The build-version stamp's font size (bottom-left of the main menu).
/// 48px is the smallest size that keeps the standard 8px outline clear of
/// the SDF clamp floor (see DESIGN → Platform Seam → SDF text outline).
const main_menu_version_font_size: i32 = 48;
/// The stamp text: "v" + the build version (comptime concat - the version
/// is a build-time constant).
const version_stamp_text = "v" ++ build_info.game_version;

pub fn buildMainMenu(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    continue_available: bool,
    /// The session's persistent dir path (the buildOptionsMenu convention;
    /// threaded from `SessionState.persistent_dir_path`). Null on web - the
    /// web signal both web-only surfaces derive from: the Import Game
    /// button + the web storage disclaimer (a browser upload / a download is
    /// the cross-session path when there is no real dir). Native has a path -
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
    // Import Game (web only - the on_web signal): uploads a taplop.zip OVER
    // the game folder - the web build's cross-session RESTORE path (browser
    // storage never persists sessions; a downloaded archive is the only
    // durable home, Export Game writes it). The overlay lands via the
    // every-frame marker poll + the session re-boots at the frame boundary
    // - see game_zip.zig + DESIGN → File System & IO → Web storage model.
    if (on_web) {
        buttons[button_count] = .{
            .label = "Import Game",
            .action = .import_game,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Uploads a taplop.zip over your game folder (replaces the current session)",
            ))}) },
        };
        button_count += 1;
    }
    // Opens the editor browser (the tabbed modal - browse + create
    // editor content; the mission kind today). See DESIGN → Architecture
    // → Level Editor → The editor browser.
    buttons[button_count] = .{ .label = "Editor", .action = .toggle_editor_browser };
    button_count += 1;

    const total_height = rowWidth(@intCast(button_count), panel_button_height, ui_gap);
    // The web storage disclaimer (web only, the chosen wording - the
    // `disclaimer_lines` array above): centered lines above the title,
    // part of the same centered block (the disclaimer band sits on top,
    // then the title band, then the buttons).
    const disclaimer_band_height: i32 = if (on_web)
        disclaimer_lines.len * main_menu_disclaimer_font_size +
            (disclaimer_lines.len - 1) * main_menu_disclaimer_gap +
            main_menu_title_gap
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
        // One label per line (a '\n' inside a single label would render
        // right but measure as one line - the wrapRow hard-break lesson;
        // plain labels get no newline handling).
        for (disclaimer_lines, 0..) |line, line_index| {
            const line_width = font_metrics.measureSpanWidth(text(line), main_menu_disclaimer_font_size);
            try elements.append(allocator, .{ .text_label = .{
                .text = line,
                .screen_position = .{
                    .x = origin.x + @divTrunc(menu_button_width - line_width, 2),
                    .y = origin.y + @as(i32, @intCast(line_index)) *
                        (main_menu_disclaimer_font_size + main_menu_disclaimer_gap),
                },
                .font_size = main_menu_disclaimer_font_size,
                .outlined = true,
                .blocks_input = false,
            } });
        }
    }

    try elements.append(allocator, .{ .text_label = .{
        .text = title,
        .screen_position = .{
            .x = origin.x + @divTrunc(menu_button_width - title_width, 2),
            .y = origin.y + disclaimer_band_height,
        },
        .font_size = main_menu_title_font_size,
        .outlined = true,
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

    // The build-version stamp (bottom-left corner): the game_version
    // string (YYYY.MM.<commits this month>[-dirty], computed at build
    // time from git - see build.zig computeGameVersion; the same string
    // the session log records). Outlined like the title + disclaimer
    // (same background, same readability pass); non-interactive.
    try elements.append(allocator, .{ .text_label = .{
        .text = version_stamp_text,
        .screen_position = .{
            .x = screen.x + ui_gap,
            .y = screen.y + screen.height - main_menu_version_font_size - ui_gap,
        },
        .font_size = main_menu_version_font_size,
        .outlined = true,
        .blocks_input = false,
    } });

    // The upstream-repo link (bottom-right, mirroring the stamp): the
    // `origin` remote's URL (build.zig computeRepoUrl) as the label - the
    // thing you act on is the thing shown. The click is platform-split
    // (browser_url): web opens a new browser tab, native copies the URL
    // to the clipboard - the tooltip says which. A spriteless button
    // hit-rect over outlined text (the emitPanelButton element pattern
    // minus the panel); NOT emitted when the build carries no repo URL
    // (no git / no origin / unrecognized form).
    if (build_info.repo_url.len > 0) {
        const link_label = build_info.repo_url;
        const link_tooltip_text = if (on_web)
            "Opens link in a new tab"
        else
            "Copies link to your clipboard";
        const link_tooltip = Tooltip{ .body = try allocator.dupe(TooltipRow, &.{
            try spanRow(allocator, text(link_tooltip_text)),
        }) };
        const link_width = font_metrics.measureSpanWidth(text(link_label), main_menu_version_font_size);
        const link_position: types.ScreenPosition = .{
            .x = screen.x + screen.width - link_width - ui_gap,
            .y = screen.y + screen.height - main_menu_version_font_size - ui_gap,
        };
        try elements.append(allocator, .{ .button = .{
            .screen_position = link_position,
            .width = link_width,
            .height = main_menu_version_font_size,
            .action = .open_repo_link,
            .tooltip = link_tooltip,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = link_label,
            .screen_position = link_position,
            .font_size = main_menu_version_font_size,
            .outlined = true,
            .blocks_input = false,
        } });
    }
}

test "buildMainMenu: session verbs + mode entries only; Settings/Credits live in the options menu" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
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
    // The build-version stamp: outlined, pinned near the bottom-left
    // corner.
    {
        var found_version_stamp = false;
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, version_stamp_text)) {
                    found_version_stamp = true;
                    try std.testing.expect(label.outlined);
                    try std.testing.expect(label.screen_position.x <= screen.x + 100);
                    try std.testing.expect(label.screen_position.y >= screen.y + screen.height - 100);
                }
            },
            else => {},
        };
        try std.testing.expect(found_version_stamp);
    }
    // The upstream-repo link: a button hit-rect + an outlined label (the
    // URL itself) in the bottom-right corner, with the platform's tooltip
    // (web opens a tab; this invocation is the web signal). Conditional
    // on the build carrying a repo URL (a tarball build without git
    // emits no link).
    if (build_info.repo_url.len > 0) {
        var found_link_button = false;
        var found_link_label = false;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .open_repo_link) {
                    found_link_button = true;
                    try std.testing.expect(button.screen_position.x + button.width >= screen.x + screen.width - 100);
                    try std.testing.expect(button.screen_position.y >= screen.y + screen.height - 100);
                    try std.testing.expect(button.tooltip != null);
                    if (button.tooltip) |tooltip| {
                        try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
                        try std.testing.expectEqual(@as(usize, 1), tooltip.body[0].len);
                        try std.testing.expectEqualStrings("Opens link in a new tab", tooltip.body[0][0].text);
                    }
                }
            },
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, build_info.repo_url)) {
                    found_link_label = true;
                    try std.testing.expect(label.outlined);
                }
            },
            else => {},
        };
        try std.testing.expect(found_link_button);
        try std.testing.expect(found_link_label);
    }
    for ([_]types.Action{ .toggle_settings, .toggle_credits }) |moved| {
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

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Web (the null persistent-dir-path signal): the Import Game button is
    // present (with a tooltip) + the storage disclaimer is present above
    // the title (every line of the chosen wording - DESIGN → Web storage
    // model) with the standard outline, and the title is outlined too
    // (the readability pass).
    {
        var elements: UiElementList = .empty;
        try buildMainMenu(&elements, allocator, metrics, screen, true, null, button_color);
        var import_button: ?Button = null;
        var found_outlined_title = false;
        var found_disclaimer_lines = @as([disclaimer_lines.len]bool, @splat(false));
        for (elements.items) |element| switch (element) {
            .button => |b| {
                if (b.action == .import_game) import_button = b;
            },
            .text_label => |label| {
                for (disclaimer_lines, 0..) |expected, index| {
                    if (std.mem.eql(u8, label.text, expected)) {
                        found_disclaimer_lines[index] = true;
                        try std.testing.expect(label.outlined);
                    }
                }
                if (std.mem.eql(u8, label.text, "taplop")) {
                    found_outlined_title = true;
                    try std.testing.expect(label.outlined);
                }
            },
            else => {},
        };
        const found = import_button orelse @panic("no Import Game button on web");
        try std.testing.expect(found.tooltip != null);
        for (found_disclaimer_lines) |found_line| try std.testing.expect(found_line);
        try std.testing.expect(found_outlined_title);
    }

    // Native (a real persistent dir path): no button, no disclaimer.
    {
        var elements: UiElementList = .empty;
        try buildMainMenu(&elements, allocator, metrics, screen, true, "zig-cache/fake-persistent-dir", button_color);
        var found_native_link = false;
        for (elements.items) |element| switch (element) {
            .button => |b| {
                try std.testing.expect(b.action != .import_game);
                // The repo link is NOT web-only - native shows it too, with
                // the clipboard tooltip (the platform's click behavior).
                if (b.action == .open_repo_link) {
                    found_native_link = true;
                    if (b.tooltip) |tooltip| {
                        try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
                        try std.testing.expectEqual(@as(usize, 1), tooltip.body[0].len);
                        try std.testing.expectEqualStrings("Copies link to your clipboard", tooltip.body[0][0].text);
                    }
                }
            },
            .text_label => |label| try std.testing.expect(
                std.mem.indexOf(u8, label.text, "WEB DISCLAIMER:") == null,
            ),
            else => {},
        };
        if (build_info.repo_url.len > 0) try std.testing.expect(found_native_link);
    }
}
