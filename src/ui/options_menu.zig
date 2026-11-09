//! The options menu: the full-screen 9-slice overlay stack of
//! context-specific menu buttons (the `.escape` toggle surface - DESIGN →
//! UI Framework). One of menus.zig's per-surface splits.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
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
const UiElement = ui_element.UiElement;
const Button = ui_element.Button;
const rowWidth = ui_element.rowWidth;
const ui_gap = ui_element.ui_gap;
const panel_button_height = ui_element.panel_button_height;
const menu_button_width = ui_element.menu_button_width;
const menu_button_font_size = ui_element.menu_button_font_size;
const spanRow = ui_tooltip.spanRow;
const buildMissionFail = @import("screens.zig").buildMissionFail;

/// Build the options menu: a full-screen 9-slice panel background with a
/// centered stack of `menu_button_width` buttons (same design as the main
/// menu). Context-specific: the button list depends on the current screen.
/// No close button anywhere - the menu closes via the `.escape` action
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
    /// and hides the campaign Export Save path - the run's player_data is
    /// temporary, rebuilt from the editor loadout (see DESIGN → Level
    /// Editor → Playtest/validate framing).
    editor_run: ?types.EditorMode,
    button_color: Color,
    /// Where the exported save lands, for the Export Save tooltip. Native:
    /// the resolved persistent dir (tooltip: "Saves to <dir>/saves/"). Web:
    /// null - the export IS a browser download (tooltip: "Triggers a file
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
    // name the RUN, not the mission - and restart genuinely re-runs it
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
    // Hidden in the editor - the save the player expects there is the
    // MISSION being edited (a separate future slice), not the campaign
    // save - and hidden during an editor run (playtest/validate): the
    // run's player_data is temporary (rebuilt from the editor loadout,
    // restored on exit), so an export mid-run would write the throwaway
    // run data as a campaign save. Also hidden on the main menu - no
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

    // The editor's own save (the mission being edited) - replaces the
    // campaign Export Save path above, which is hidden in the editor.
    // Also on ctrl+S (the binding ships in default_settings.txt).
    if (current_screen == .editor) {
        const save_body = if (persistent_dir_path) |dir|
            try std.fmt.allocPrint(allocator, "Ctrl+S - saves to {s}/missions/", .{dir})
        else
            "Ctrl+S - saves to the browser's persistent storage";
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
        // mission being edited (no unsaved-changes confirm - save first
        // if in doubt; ctrl+S is cheap). Also on ctrl+O (the binding
        // ships in default_settings.txt).
        buttons[button_count] = .{
            .label = "Open Mission",
            .action = .toggle_editor_browser,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Ctrl+O - browse your saved missions and the official ones",
            ))}) },
        };
        button_count += 1;

        // The fresh-mission open (also the editor browser's New Mission
        // button + ctrl+N): replaces the mission being edited with a
        // new one-level template mission (no unsaved-changes confirm,
        // same as an open - save first if in doubt).
        buttons[button_count] = .{
            .label = "New Mission",
            .action = .new_editor_mission,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Ctrl+N - replaces the mission being edited with a fresh one",
            ))}) },
        };
        button_count += 1;

        // Revalidate: re-certify the STORED validation replay against the
        // current saved content - the author's post-edit repair for edits
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

    // Export Game (web only - the persistent-dir-path-null signal, the
    // same web case the Export Save tooltip uses): downloads ziglop.zip,
    // the FULL game folder (settings, saves, custom missions) - the web
    // build's cross-session backup path (browser storage never persists
    // sessions). Present in EVERY variant (the options menu is the only
    // menu surface reachable mid-level, so in-session backups are always
    // possible); a game in progress writes the autosave FIRST (the
    // handler), so mid-level progress is in the zip. Native has no button
    // - the real persistent dir IS the game folder.
    if (persistent_dir_path == null) {
        buttons[button_count] = .{
            .label = "Export Game",
            .action = .export_game,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Downloads ziglop.zip - your full game folder (settings, saves, custom missions)",
            ))}) },
        };
        button_count += 1;
    }

    // Settings: opens the settings overlay on top of this one (drill-in).
    // Present in every context the options menu appears in.
    buttons[button_count] = .{ .label = "Settings", .action = .open_settings };
    button_count += 1;

    // The main-menu variant: no session verbs (nothing to restart/exit/
    // export) and no Exit to Main Menu (already there) - Credits + the
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

test "buildOptionsMenu: Revalidate Mission is editor-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
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

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    var elements: UiElementList = .empty;
    try buildOptionsMenu(&elements, allocator, metrics, screen, .main_menu, null, button_color, null);
    // The main-menu variant: Settings + Credits + Exit Game (tests run
    // native - the web build omits Exit Game), and none of the session
    // verbs, the editor block, or Exit to Main Menu. No Continue - like
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

test "buildOptionsMenu: Export Save tooltip reflects the save destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
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
    // the mission being edited). Settings + Exit to Main Menu remain -
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
        try std.testing.expectEqualStrings("Ctrl+S - saves to /home/tester/.ziglop/missions/", save_tooltip_text);

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
        try std.testing.expectEqualStrings("Ctrl+N - replaces the mission being edited with a fresh one", new_tooltip_text);
    }
}

test "buildOptionsMenu: Export Game on every variant, web only (null persistent dir path)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Web (null path): present on EVERY variant with the ziglop.zip
    // tooltip + label - the options menu is the only menu surface
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
            "Downloads ziglop.zip - your full game folder (settings, saves, custom missions)",
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

    // Native (a path): no button at all - the real persistent dir IS the
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

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    for ([_]types.EditorMode{ .playtest, .validate }) |run_mode| {
        const restart_label = if (run_mode == .playtest) "Restart Playtest" else "Restart Validation";
        const exit_label = if (run_mode == .playtest) "Exit Playtest" else "Exit Validation";

        // The options menu names the RUN on the restart/exit buttons and
        // offers NO campaign Export Save (the run's player_data is
        // temporary - rebuilt from the editor loadout, discarded on exit).
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
        // element) - match the immediately-preceding button's action.
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
