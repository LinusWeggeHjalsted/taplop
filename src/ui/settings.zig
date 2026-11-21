//! The settings screen: the two-tab full-screen overlay (settings controls
//! + the keybinds tab's rebinding list - DESIGN → UI Framework → Settings
//! screen + DESIGN → Input → Binding contexts). One of menus.zig's
//! per-surface splits; the shared scrollbar emitter lives in emit.zig.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const keybind_edit = @import("keybind_edit.zig");
const emit = @import("emit.zig");
const ui_tooltip = @import("tooltip.zig");

const Action = types.Action;
const Rectangle = types.Rectangle;
const Color = types.Color;
const text = ui_element.text;
const FontMetrics = ui_element.FontMetrics;
const UiElementList = ui_element.UiElementList;
const emitPanelButton = emit.emitPanelButton;
const Slider = ui_element.Slider;
const SlotRef = ui_element.SlotRef;
const rowWidth = ui_element.rowWidth;
const Row = ui_element.Row;
const ui_gap = ui_element.ui_gap;
const panel_button_height = ui_element.panel_button_height;
const menu_button_font_size = ui_element.menu_button_font_size;
const lineHeight = ui_element.lineHeight;
const scrollbar_width = ui_element.scrollbar_width;
const spanRow = ui_tooltip.spanRow;
const negative_color = ui_tooltip.negative_color;

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
/// Toggle button (On/Off) width - sits in the control area of a row.
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

/// The Settings tab's control rows (the 12 toggles/choices/sliders) -
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
    // against the label - measured per-row so the control sits right after
    // the label text, not at a fixed column). Vertically stacked below the
    // header, centered as a group between header and Back button.

    // 12 rows (6 toggle/choice + 5 slider + 1 fps toggle):
    //   0. Master Volume (slider 0-100)
    //   1. Music Volume (slider 0-100)
    //   2. Sound Effects Volume (slider 0-100)
    //   3. Render FPS Cap (slider 0-256, 0 = Uncapped)
    //   4. Animation FPS (slider 1-16)
    //   5. VSync (toggle)
    //   6. Camera Zoom (4-button choice)
    //   7. Render Resolution (4-button choice)
    //   8. Player Color (6-swatch choice)
    //   9. Auto-skip attack step (toggle)
    //  10. Auto-target at cursor (toggle)
    //  11. Show FPS (toggle)
    // The 12 rows flow into TWO side-by-side columns of 6 (the wide
    // reference screen makes a single left-anchored column wasted space -
    // and a single 12-row column needs 1792px where the region between the
    // tab row and the Back button has ~1610: the last row would overlap the
    // Back button. It did even before the tab row - the tab row made the
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

    // Helper: emit a slider row - label (flush left) + slider control +
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

    // ── Slider rows (0-4) ──

    // Row 0: Master Volume (0-100).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.master_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Master Volume", .master_volume, 0, 100, settings.master_volume, value_label, row.x, row.y);
    }
    row_index += 1;

    // Row 1: Music Volume (0-100).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.music_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Music Volume", .music_volume, 0, 100, settings.music_volume, value_label, row.x, row.y);
    }
    row_index += 1;

    // Row 2: Sound Effects Volume (0-100).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.sound_effects_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Sound Effects Volume", .sound_effects_volume, 0, 100, settings.sound_effects_volume, value_label, row.x, row.y);
    }
    row_index += 1;

    // Row 3: Render FPS Cap (0-256, 0 = Uncapped).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label: []const u8 = if (settings.render_fps_cap == 0)
            "Uncapped"
        else
            std.fmt.allocPrint(allocator, "{d}", .{settings.render_fps_cap}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Render FPS Cap", .render_fps_cap, 0, 256, settings.render_fps_cap, value_label, row.x, row.y);
    }
    row_index += 1;

    // Row 4: Animation FPS (1-16).
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const value_label = std.fmt.allocPrint(allocator, "{d}", .{settings.animation_fps}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Animation FPS", .animation_fps, 1, 16, settings.animation_fps, value_label, row.x, row.y);
    }
    row_index += 1;

    // ── Toggle / choice rows (5-9) ──

    // Row 5: VSync toggle. Label is platform-specific: on web the setting
    // is a no-op - the browser's requestAnimationFrame paces rendering to
    // the display refresh regardless (rAF IS vsync on web; no page code can
    // out-run it). On native it's a real GLFW swap-interval toggle that only
    // applies at window creation, hence the restart note.
    {
        const row = settingsControlRowRect(content_x, content_width, rows_y_start, row_index);
        const vsync_label = if (@import("builtin").target.os.tag == .emscripten)
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

    // Row 6: Camera Zoom - 4 buttons (25/50/75/100 hundredths → display as %).
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

    // Row 7: Render Resolution - 4 buttons (720p/1080p/1440p/2160p). The
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
                .{ .id = .render_resolution, .choice_value = @backingInt(resolution) },
                settings.render_resolution == resolution,
                button_color,
            );
        }
    }
    row_index += 1;

    // Row 8: Player Color - 6 swatches (player gradient indices 0-5).
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
/// "Settings" header, a column of control rows (toggle/choice - sliders
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
    // Full-screen modal background - blocks input to the surface behind it.
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
    // is a view affordance (direct UiState write, off the undo timeline -
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
    // Content per tab - the tab row above is tab-independent chrome.
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
        .toggle_settings,
        button_color,
        null,
    );

    // Reset to Defaults, bottom-right - mirrors the Back button's metrics.
    // Direct click, no confirm (the timestamped backup is the safety net);
    // the tooltip says what it does. The command rides the `.edit_keybind`
    // channel (`.reset_defaults` is exempt from the keybinds-tab gate - a
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

/// A key/button id's display label ("Ctrl", "Z", "PgUp", "LMB") - a view-only
/// prettification of the raw id. Known idioms map to short labels; "KeyX" /
/// "DigitN" strip their prefixes (slices INTO the id - the id outlives the
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
/// constant) - comptime-var buffers copied into a table do NOT materialize
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
/// event log") - comptime-generated from the enum field names (machine-walked:
/// a new Action's label appears with no edit here).
fn actionDisplayLabel(action: types.Action) []const u8 {
    const labels = comptime blk: {
        @setEvalBranchQuota(20_000);
        const field_names = @typeInfo(types.Action).@"enum".field_names;
        var table: [field_names.len][]const u8 = undefined;
        for (field_names, 0..) |field_name, index| {
            table[index] = makePrettifiedLabel(field_name);
        }
        break :blk table;
    };
    return labels[@backingInt(action)];
}

/// A context set's display label ("Anytime", "Editor + Menu") -
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
    if (set.campaign_editor) mask |= 1 << 3;
    if (set.menu) mask |= 1 << 4;
    if (set.error_popup) mask |= 1 << 5;
    return labels[mask];
}

/// The context members' display names, indexed by the mask bit each occupies
/// in `contextSetDisplayLabel`'s pack.
const context_set_member_names = [_][]const u8{ "Anytime", "Game", "Editor", "Campaign editor", "Menu", "Error popup" };

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
/// below a certain width (the corner tiles dominate the panel - see TODO →
/// Cross-cutting polish), and single-character keys (I, U, 1) would
/// otherwise produce stub panels; the label centers in the panel so the
/// extra width reads as a button, not stretched text.
const keybind_min_panel_width: i32 = 160;

/// Sort display order: by action (enum declaration order - undo, redo,
/// escape, ...), stable so an action's multiple combos keep their file
/// order. The file's order is load order, not a display order.
fn bindingActionLessThan(_: void, left: types.InputBinding, right: types.InputBinding) bool {
    return @backingInt(left.action) < @backingInt(right.action);
}

/// The Keybinds tab's list + editing UI. READ side: one row per binding -
/// modifier/key panels ("+" between; prettified ids via `keyIdDisplayLabel`)
/// and the action panel directly after the combo, labeled "Action -
/// Contexts" (the derived context set). Rows sorted by action (stable) so an
/// action's combos sit adjacent.
///
/// EDIT side (TODO → Keybind editor slice 4): every row's combo area starts a
/// LISTENING rekey (the row swaps to a highlighted "Press a key..." panel; the
/// capture seam lives in `translateInput` - binding translation is
/// suppressed while any edit is active) and its action panel opens the
/// right-column action PICKER (the full scrollable action list); each row
/// carries X (remove - direct, no confirm) and + (add a combo for its
/// action). A capture or picker pick lands in a PENDING row: the proposed
/// combo + Confirm/Cancel buttons + the steal warning in the warn color
/// ("... currently fires Undo (game) - confirming will remove it"); confirming
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
    // binding list ALWAYS occupies the left half - a stable layout that
    // doesn't reflow when the picker opens.
    const picker_x = screen.x + @divTrunc(screen.width, 2) + @divTrunc(ui_gap, 2);

    // The standalone Add button (top of the list - always visible): opens
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
    // an extra row below its action's row group - where the confirmed
    // combo will appear (the display is action-sorted) - or at the top of
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

    // Display order: indices sorted by action (stable) - each row carries
    // its original binding index for edit targeting.
    const order = try allocator.alloc(usize, bindings.len);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, bindings, bindingIndexActionLessThan);

    const RowEntry = union(enum) {
        add_edit,
        binding: usize,
    };

    // The proposal's insert position: after the LAST row of its action's
    // group in display order (0 = top - the action has no bindings yet).
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

        // Keep the proposal row on screen - it is the user's next
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
                // button - a click ANYWHERE is a mouse capture, handled by
                // the capture seam), or the pending proposal row.
                switch (add_edit.?) {
                    // An add never opens the picker (the standalone add's
                    // picker phase converts to listening on pick).
                    .picker => {},
                    .listening => |target| {
                        const label_text = try std.fmt.allocPrint(allocator, "Press a key for {s}... (Esc to cancel)", .{actionDisplayLabel(target.add)});
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
                    // button with NO command - a click is a mouse capture
                    // through the seam; the handler no-ops a payload-less
                    // command), the action panel kept for context.
                    const label_text = "Press a key... (Esc to cancel)";
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

                // X (remove - direct) + + (add a combo for this action).
                panel_x += try emitKeybindCommandPanel(elements, allocator, font_metrics, "X", panel_x, row_y, button_color, .{ .remove = index }, false, "Delete");
                panel_x += settings_row_gap;
                _ = try emitKeybindCommandPanel(elements, allocator, font_metrics, "+", panel_x, row_y, button_color, .{ .add = binding.action }, false, "Add another keybind");
            },
        }
    }

    // Scrollbar (only when the binding list overflows the window): track +
    // thumb at the left column's right edge (the screen midpoint).
    if (rows.items.len > visible_rows) {
        try emit.emitScrollbar(
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
    // scrollable action list - every Action, bound or not, labeled
    // "Action - Contexts". Picking one either moves the target row's combo
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
                try emit.emitScrollbar(
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
    return @backingInt(bindings[left].action) < @backingInt(bindings[right].action);
}

/// "Action - Contexts" (the derived context set) - the action panel + picker
/// row label.
fn actionPanelLabel(allocator: std.mem.Allocator, action: types.Action) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} - {s}", .{
        actionDisplayLabel(action),
        contextSetDisplayLabel(types.actionBindingContexts(action)),
    });
}

/// Panel + centered label (returns the panel width - the caller places the
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
    // pending (the modal-capture-state convention - safe because capture
    // happens during listening; Escape cancels the same way).
    panel_x += try emitKeybindCommandPanel(elements, allocator, font_metrics, "Confirm", panel_x, row_y, button_color, .confirm, true, null);
    panel_x += settings_row_gap;
    panel_x += try emitKeybindCommandPanel(elements, allocator, font_metrics, "Cancel", panel_x, row_y, button_color, .cancel, false, null);

    // The steal warning (see findKeybindSteal): the combo currently fires
    // another binding - confirming REMOVES it - or duplicates its own
    // action's combo (confirming dedupes).
    if (pending.stolen_index) |stolen_index| {
        const stolen = bindings[stolen_index];
        const warning_text = if (stolen.action == pending.binding.action)
            try std.fmt.allocPrint(allocator, "This combo is already bound to {s} - confirming removes the duplicate", .{actionDisplayLabel(stolen.action)})
        else
            try std.fmt.allocPrint(allocator, "This combo currently fires {s} ({s}) - confirming will remove it", .{
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

test "buildSettingsPanel: tab row on both tabs; settings tab keeps control rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
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
    // is tighter - the lowest control's bottom must clear the Back button's
    // top (the Back button toggles via the same .toggle_settings action that
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
            if (button.action == .toggle_settings) {
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

test "buildSettingsPanel: keybinds tab - rows, key panels, action labels + context tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    // Two combos on ONE action (undo: ctrl+Z and U - adjacent rows, no
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
    // appears inside "Undo - Anytime" action labels).
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
            if (std.mem.eql(u8, label.text, "Undo - Anytime")) undo_anytime += 1;
            if (std.mem.eql(u8, label.text, "Confirm - Game")) confirm_game += 1;
            if (std.mem.eql(u8, label.text, "Select editor tool - Editor")) select_tool_editor += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 0), undo_headers);
    try std.testing.expectEqual(@as(usize, 1), ctrl_labels);
    try std.testing.expectEqual(@as(usize, 1), z_labels);
    try std.testing.expectEqual(@as(usize, 1), u_labels);
    // "+" appears as BOTH the combo separator (ctrl + Z) and each row's
    // add-combo button label - at least the separator here.
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
    // The min-width contract: every keybind panel (key/modifier/action -
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

test "buildSettingsPanel: keybinds tab add proposal - below its action's group, kept on screen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const row_stride = settings_row_height + settings_row_gap;
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // A row's `+` (an add listening on an EXISTING action): the proposal
    // renders directly below that action's row group - one row_stride
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
        const proposal_text = try std.fmt.allocPrint(allocator, "Press a key for {s}... (Esc to cancel)", .{actionDisplayLabel(.undo)});
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "Undo - Anytime")) undo_label_y = label.screen_position.y;
                if (std.mem.eql(u8, label.text, "Confirm - Game")) confirm_label_y = label.screen_position.y;
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
        const proposal_text = try std.fmt.allocPrint(allocator, "Press a key for {s}... (Esc to cancel)", .{actionDisplayLabel(.dump_event_log)});
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "Undo - Anytime")) undo_label_y = label.screen_position.y;
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
    // last display action - the proposal would land beyond the window,
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

        const proposal_text = try std.fmt.allocPrint(allocator, "Press a key for {s}... (Esc to cancel)", .{actionDisplayLabel(action_tags[59])});
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

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    // 60 distinct actions - enough rows (headers + combos) to overflow any
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
    // every offset - whole visible rows only).
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

test "buildSettingsPanel: keybinds tab scrollbars - track + thumb per overflowing column, none when content fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    // 60 distinct actions - enough rows to overflow either column's window
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

    // Picker open: BOTH columns overflow - the picker's track flush to the
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
