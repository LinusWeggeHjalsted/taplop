//! In-game screen surfaces: the pending-error popup (modal, scrollable
//! message + Dismiss — see DESIGN → Error Handling), the top bar (options
//! button), and the mission-complete / mission-fail overlays (stats +
//! clone-harvest rewards; restart/exit actions — see DESIGN → Clones).

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const ui_tooltip = @import("tooltip.zig");
const state = @import("../state.zig");
const validation_replay = @import("../validation_replay.zig");

const Action = types.Action;
const Rectangle = types.Rectangle;
const Color = types.Color;
const weapon_type_count = @typeInfo(types.WeaponType).@"enum".fields.len;
const GameState = state.GameState;
const text = ui_element.text;
const FontMetrics = ui_element.FontMetrics;
const UiElementList = ui_element.UiElementList;
const Button = ui_element.Button;
const screenRect = ui_element.screenRect;
const rowWidth = ui_element.rowWidth;
const Row = ui_element.Row;
const ui_gap = ui_element.ui_gap;
const panel_button_height = ui_element.panel_button_height;
const menu_button_width = ui_element.menu_button_width;
const menu_button_font_size = ui_element.menu_button_font_size;
const inventory_slot_size = ui_element.inventory_slot_size;
const top_bar_height = ui_element.top_bar_height;
const top_bar_slot_size = ui_element.top_bar_slot_size;
const lineHeight = ui_element.lineHeight;
const spanRow = ui_tooltip.spanRow;
const emitIconButton = emit.emitIconButton;
const emitPanelButton = emit.emitPanelButton;
const emitMaterialIcons = emit.emitMaterialIcons;
const wrapRow = ui_element.wrapRow;
const tooltip_panel_sprite = ui_tooltip.tooltip_panel_sprite;
const button_background_sprite_id = emit.button_background_sprite_id;



// Error popup sizing — a modal centered panel for recoverable load
// failures (see SessionState.pending_error). Reuses the tooltip wrap
// machinery (wrapRow / measureRowWidth / lineHeight) for the message body.
// The body scrolls when the wrapped text exceeds the max body height.
pub const error_popup_max_width: i32 = 1280;
pub const error_popup_padding: i32 = 32;
pub const error_header_font_size: i32 = 72;
pub const error_body_font_size: i32 = 56;
pub const error_header_gap: i32 = 24; // gap below the "Error" header
pub const error_button_gap: i32 = 32; // gap above the Dismiss button
pub const error_dismiss_button_width: i32 = 512;
pub const error_dismiss_button_font_size: i32 = 64;
/// Max body region height before scrolling kicks in. Leaves room for the
/// header + Dismiss button + padding within the 2160px reference height.
/// The visible line count is derived from this via `lineHeight` — whole
/// lines only (the region height is the visible count × line height, so
/// text placement is identical at every scroll offset).
pub const error_popup_max_body_height: i32 = 1600;
/// Scrollbar geometry (reference-space pixels). Drawn only when the body
/// content overflows the visible region.
pub const error_scrollbar_width: i32 = 12;
pub const error_scrollbar_gap: i32 = 16; // gap between body text and scrollbar

/// Build a modal, centered, scrollable error popup showing `message` with
/// a Dismiss button. Appended last in view() so it draws on top of
/// everything; the panel's `blocks_input = true` halts hit-testing within
/// its bounds. handleAnytimeInput gates all input except `dismiss_error` +
/// the scroll actions while a pending error is set (see
/// SessionState.pending_error).
///
/// When the wrapped body exceeds `error_popup_max_body_height`, the body
/// scrolls by LINES — the game-wide row-scroll convention (the inspector /
/// skills-panel / browser model): `session.error_scroll_offset` is the
/// index of the first visible body line, the wheel scrolls one line per
/// notch (wheel-up = earlier lines), and the arrow keys 3 lines per press
/// (see handleAnytimeInput). Only the window's lines are emitted, drawn
/// from the top of the body region. The offset is clamped to
/// `[0, max_scroll_lines]` here (the view is the only place that knows the
/// wrapped line count); the input site clamps the lower bound. Pure over
/// the message + frame arena, aside from that scroll-offset clamp.
pub fn buildErrorPopup(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    session: *state.SessionState,
    message: []const u8,
    button_color: Color,
) !void {
    const content_width_limit = error_popup_max_width - 2 * error_popup_padding;

    const header_lines = try wrapRow(
        allocator,
        font_metrics,
        try spanRow(allocator, text("Error")),
        error_header_font_size,
        content_width_limit,
    );
    const body_lines = try wrapRow(
        allocator,
        font_metrics,
        try spanRow(allocator, text(message)),
        error_body_font_size,
        content_width_limit,
    );

    const body_line_height = lineHeight(error_body_font_size);
    // Whole visible lines only — the region height is a multiple of the
    // line height, so text placement is identical at every offset.
    const max_visible_lines: usize = @intCast(@divTrunc(error_popup_max_body_height, body_line_height));
    const visible_line_count: usize = @min(body_lines.len, max_visible_lines);
    const scrolls = body_lines.len > visible_line_count;
    const body_content_height: i32 = @intCast(body_lines.len * @as(usize, @intCast(body_line_height)));
    const visible_body_height: i32 = @intCast(visible_line_count * @as(usize, @intCast(body_line_height)));
    // Clamp the scroll offset (authoritative — the input handler can't
    // know the wrapped line count). Offset is in LINES: the index of the
    // first visible body line.
    const max_scroll_lines: i32 = @intCast(body_lines.len - visible_line_count);
    if (session.error_scroll_offset < 0) session.error_scroll_offset = 0;
    if (session.error_scroll_offset > max_scroll_lines) session.error_scroll_offset = max_scroll_lines;
    const first_visible_line: usize = @intCast(session.error_scroll_offset);

    // Content width = widest visual line, capped to the limit. The Dismiss
    // button + scrollbar also constrain width so they fit inside the panel.
    var content_width: i32 = error_dismiss_button_width;
    if (scrolls) content_width += error_scrollbar_width + error_scrollbar_gap;
    for (header_lines) |line| {
        const line_width = @min(font_metrics.measureRowWidth(line, error_header_font_size), content_width_limit);
        if (line_width > content_width) content_width = line_width;
    }
    for (body_lines) |line| {
        const line_width = @min(font_metrics.measureRowWidth(line, error_body_font_size), content_width_limit);
        if (line_width > content_width) content_width = line_width;
    }

    // Content height: header lines + header gap + visible body + button gap + button.
    const header_height: i32 = @intCast(header_lines.len * @as(usize, @intCast(lineHeight(error_header_font_size))));
    const content_height = header_height +
        error_header_gap +
        visible_body_height +
        error_button_gap +
        panel_button_height;

    const panel_width = content_width + 2 * error_popup_padding;
    const panel_height = content_height + 2 * error_popup_padding;

    // Center on screen, clamped to the reference resolution.
    const panel_rect = screenRect().placeCenter(panel_width, panel_height);
    const panel_pos = panel_rect.position();

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = tooltip_panel_sprite,
        .screen_position = panel_pos,
        .width = panel_width,
        .height = panel_height,
        // Modal: halts hit-testing within the panel bounds so clicks on the
        // popup (not on the button) are swallowed rather than passing through.
        .blocks_input = true,
    } });

    const content_x = panel_pos.x + error_popup_padding;
    var y = panel_pos.y + error_popup_padding;

    // Header lines.
    for (header_lines) |line| {
        var x = content_x;
        for (line) |span| {
            try elements.append(allocator, .{ .text_label = .{
                .text = span.text,
                .screen_position = .{ .x = x, .y = y },
                .color = span.color,
                .font_size = error_header_font_size,
                .bold = true,
                .blocks_input = false,
            } });
            x += font_metrics.measureSpanWidth(span, error_header_font_size);
        }
        y += lineHeight(error_header_font_size);
    }
    y += error_header_gap;

    // Body: emit only the window's lines, drawn from the TOP of the body
    // region (the window's first line renders at `body_top` — lines above
    // the window are simply not emitted). Skipping the out-of-window
    // lines keeps the element list small and the hit-test set clean.
    const body_top = y;
    const last_visible_line = first_visible_line + visible_line_count;
    for (body_lines[first_visible_line..last_visible_line]) |line| {
        var x = content_x;
        for (line) |span| {
            try elements.append(allocator, .{ .text_label = .{
                .text = span.text,
                .screen_position = .{ .x = x, .y = y },
                .color = span.color,
                .font_size = error_body_font_size,
                .blocks_input = false,
            } });
            x += font_metrics.measureSpanWidth(span, error_body_font_size);
        }
        y += body_line_height;
    }

    // Scrollbar (only when the body overflows). Track + thumb on the right
    // edge of the body region. The thumb is proportional to the visible /
    // total ratio and positioned by the scroll offset (line offset over
    // line max — the same ratio as pixels).
    if (scrolls) {
        const scrollbar_x = content_x + content_width - error_scrollbar_width;
        const track_color: types.Color = .{ .r = 80, .g = 80, .b = 80 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = scrollbar_x, .y = body_top },
            .width = error_scrollbar_width,
            .height = visible_body_height,
            .color = track_color,
        } });
        const thumb_height = @max(
            @as(i32, 40),
            @divTrunc(visible_body_height * visible_body_height, body_content_height),
        );
        const thumb_y = body_top + @divTrunc(
            session.error_scroll_offset * (visible_body_height - thumb_height),
            max_scroll_lines,
        );
        const thumb_color: types.Color = .{ .r = 180, .g = 180, .b = 180 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = scrollbar_x, .y = thumb_y },
            .width = error_scrollbar_width,
            .height = thumb_height,
            .color = thumb_color,
        } });
    }

    // Dismiss button, centered horizontally in the panel. Positioned after
    // the (possibly scrolled) body region — always at the bottom, reachable.
    y = body_top + visible_body_height + error_button_gap;
    const button_rect = Rectangle{
        .x = panel_pos.x + @divTrunc(panel_width - error_dismiss_button_width, 2),
        .y = y,
        .width = error_dismiss_button_width,
        .height = panel_button_height,
    };
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        button_rect,
        "Dismiss",
        error_dismiss_button_font_size,
        .dismiss_error,
        button_color,
        null,
    );
}

/// The GLOBAL TOP BAR — the always-on-top UI layer: options, undo, and
/// redo, top-left. Emitted LAST in view()'s UI assembly, so the painter's-
/// order list draws it above everything (options menu, mission overlays,
/// error popup) and hitTest's topmost-first scan gives it click priority —
/// see DESIGN → UI Framework (global top bar). Undo/redo are available on
/// every screen and across screen transitions (anytime actions); the
/// buttons just emit the same actions the keybinds do.
///
/// Availability dimming: an unavailable undo/redo (nothing left to undo /
/// redo — `GameStateHistory.canUndo`/`canRedo`) gets the button background
/// re-drawn on top at 50% alpha, the same wash the skill cooldown uses
/// (see emit.zig's skill slot). The button stays clickable (a no-op,
/// exactly like the keybind) — the wash is the visual truth only.
///
/// The options button is NOT emitted on the main menu: that screen's own
/// button stack is its option surface, and the Escape chain (which the
/// button routes through) deliberately no-ops there — see
/// `handleEscapeKey`. The slot stays reserved so the undo/redo positions
/// don't shift between screens.
///
/// No background of its own — purely a layout region, like the bottom bar.
/// The remaining width stays reserved for the combat log (see TODO →
/// Combat Log).
pub fn buildGlobalTopBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    screen: Rectangle,
    current_screen: state.Screen,
    active_theme: types.ActiveColorTheme,
    can_undo: bool,
    can_redo: bool,
) !void {
    const p = active_theme.player_gradient.colors;
    // Match the bottom-bar skip button: background = gradient[5], icon = gradient[1].
    const c_btn_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_btn_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)];
    // The unavailable wash tint — the skill cooldown's overlay color.
    const c_dim = active_theme.darkest;

    var row = Row.init(screen.position(), top_bar_height, ui_gap);

    // Options button — flush in the top-left corner (no margin). Layered
    // background + icon, same as the skip button. Clicking it while the
    // options menu is open toggles the menu closed (the action routes
    // through the Escape chain, which closes an open menu first).
    const options_cell = row.next(top_bar_slot_size);
    if (current_screen != .main_menu) {
        try emitIconButton(
            elements,
            allocator,
            options_cell,
            button_background_sprite_id,
            "ui/icon_options",
            .toggle_options_menu,
            .{ .header = try spanRow(allocator, text("Options")) },
            c_btn_bg,
            c_btn_icon,
            false,
            null,
        );
    }

    // Undo button — same size, one `ui_gap` to the right of options. Same
    // layered background + icon treatment as the options button.
    const undo_cell = row.next(top_bar_slot_size);
    try emitIconButton(
        elements,
        allocator,
        undo_cell,
        button_background_sprite_id,
        "ui/icon_undo",
        .undo,
        .{ .header = try spanRow(allocator, text("Undo")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );
    if (!can_undo) try emitDimWash(elements, allocator, undo_cell, c_dim);

    // Redo button — mirrors the undo button; its glyph is the undo icon
    // flipped horizontally (Image.flip_horizontal — the render seam's
    // negative-source-width trick). Emitted inline rather than through
    // emitIconButton, which has no flip parameter (this is the only
    // flipped icon button).
    const redo_cell = row.next(top_bar_slot_size);
    try elements.append(allocator, .{ .button = .{
        .sprite_id = button_background_sprite_id,
        .screen_position = redo_cell.position(),
        .width = redo_cell.width,
        .height = redo_cell.height,
        .action = .redo,
        .color = c_btn_bg,
        .tooltip = .{ .header = try spanRow(allocator, text("Redo")) },
    } });
    try elements.append(allocator, .{ .image = .{
        .sprite_id = "ui/icon_undo",
        .screen_position = redo_cell.position(),
        .width = redo_cell.width,
        .height = redo_cell.height,
        .color = c_btn_icon,
        .flip_horizontal = true,
        // Sits on top of the background; let the button win the hit-test.
        .blocks_input = false,
    } });
    if (!can_redo) try emitDimWash(elements, allocator, redo_cell, c_dim);
}

/// The unavailable-state wash for a global-bar button: the button
/// background sprite re-drawn on top at 50% alpha, tinted the theme's
/// `darkest` — the same treatment a skill on cooldown gets (see
/// emit.zig's skill slot). Non-blocking, so hover/click pass through to
/// the button beneath (which no-ops exactly like the keybind).
fn emitDimWash(elements: *UiElementList, allocator: std.mem.Allocator, cell: Rectangle, dim_color: Color) !void {
    try elements.append(allocator, .{ .image = .{
        .sprite_id = button_background_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = dim_color,
        .alpha = 128,
        .blocks_input = false,
    } });
}

/// The validation stats screen's session-side context — view() builds this
/// from SessionState when the completed "mission" was a validation run
/// (MissionCompleteInfo.validation). The personal best + medal targets
/// derive from the replay FILE's turns (captured at the write site — view
/// is file-free); the targets fall back to this run's turns when no replay
/// landed (a failed write — the popup says so). See DESIGN → Custom
/// Missions & Online Services → Validation replay.
pub const ValidationCompleteContext = struct {
    personal_best_turns: ?u32,
    medal_targets: validation_replay.MedalTargets,
    overwrite_offered: bool,
};

/// Build the mission-complete overlay: a full-screen 9-slice panel with a
/// header centered at the top, a centered summary line below it, a
/// two-column area (left stats, right column) extending downward, and
/// buttons at the bottom. Rendered when `GameState.last_completed_mission`
/// is set. Two contexts share the surface:
/// - CAMPAIGN (validation == null — the hub after the player completes the
///   last level of a mission): "{name} completed" header, a "New clone:
///   [icons]" summary line, the clone-harvest rewards column, and Continue
///   + Replay Mission (+ Overwrite Clone if offered) buttons. See DESIGN →
///   Architecture + DESIGN → Clones (clone system).
/// - VALIDATION (validation != null — the editor's post-run stats screen;
///   end_validation populated the info so the overlay renders over the
///   editor): "{name} validated" header, a "Validated in N turns — Personal
///   best: M turns" summary, the medal ladder (Author / Gold / Silver /
///   Bronze — the author's own validated turns crowning the derived
///   targets), and Continue
///   + Validate Again (+ Overwrite Replay while the personal-best guard's
///   slower-run stash is on offer). See DESIGN → Custom Missions & Online
///   Services → Validation replay.
pub fn buildMissionComplete(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    info: types.MissionCompleteInfo,
    active_theme: types.ActiveColorTheme,
    validation: ?ValidationCompleteContext,
) !void {
    // Button panels tint with player gradient index 5 to read as buttons
    // against the theme-`darkest` background panel.
    const button_color = active_theme.player_gradient.colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    // Full-screen panel background.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
    } });

    // ── Header, centered at the top. ──
    const header_font_size: i32 = 128;
    const header_text = try std.fmt.allocPrint(
        allocator,
        "{s} {s}",
        .{ info.name, if (validation != null) "validated" else "completed" },
    );
    const header_width = font_metrics.measureSpanWidth(text(header_text), header_font_size);
    const header_box = screen.placeTopCenter(header_width, header_font_size, ui_gap * 4);
    try elements.append(allocator, .{ .text_label = .{
        .text = header_text,
        .screen_position = header_box.position(),
        .font_size = header_font_size,
        .blocks_input = false,
    } });

    // ── Summary line, centered below the header — branch by context. ──
    const summary_y = header_box.y + header_font_size + ui_gap * 3;
    var content_y: i32 = undefined;
    if (validation) |context| {
        // "Validated in N turns" (+ the personal best when one exists).
        const summary_font_size: i32 = 64;
        const summary_text = if (context.personal_best_turns) |best|
            try std.fmt.allocPrint(
                allocator,
                "Validated in {d} turns — Personal best: {d} turns",
                .{ info.turns_spent, best },
            )
        else
            try std.fmt.allocPrint(allocator, "Validated in {d} turns", .{info.turns_spent});
        const summary_width = font_metrics.measureSpanWidth(text(summary_text), summary_font_size);
        const summary_x = screen.x + @divTrunc(screen.width - summary_width, 2);
        try elements.append(allocator, .{ .text_label = .{
            .text = summary_text,
            .screen_position = .{ .x = summary_x, .y = summary_y },
            .font_size = summary_font_size,
            .blocks_input = false,
        } });
        content_y = summary_y + summary_font_size + ui_gap * 4;
    } else {
        // "New clone: [horizontal icons]" — shows the just-completed run's
        // converted_materials (the clone's rate numerator). The icon row is
        // horizontal + compact (96px icons) so the whole line reads as one
        // summary.
        const new_clone_icon_size: i32 = 96;
        const new_clone_label_text = "New clone:";
        const new_clone_label_font_size: i32 = 64;
        const new_clone_label_width = font_metrics.measureSpanWidth(text(new_clone_label_text), new_clone_label_font_size);
        const new_clone_icon_row_width = rowWidth(5, new_clone_icon_size, ui_gap);
        const new_clone_total_width = new_clone_label_width + ui_gap + new_clone_icon_row_width;
        const new_clone_y = header_box.y + header_font_size + ui_gap * 3;
        const new_clone_start_x = screen.x + @divTrunc(screen.width - new_clone_total_width, 2);
        try elements.append(allocator, .{ .text_label = .{
            .text = new_clone_label_text,
            .screen_position = .{ .x = new_clone_start_x, .y = new_clone_y + (new_clone_icon_size - new_clone_label_font_size) / 2 },
            .font_size = new_clone_label_font_size,
            .blocks_input = false,
        } });
        try emitMaterialIcons(
            elements,
            allocator,
            font_metrics,
            .{ .x = new_clone_start_x + new_clone_label_width + ui_gap, .y = new_clone_y },
            new_clone_icon_size,
            .horizontal,
            info.converted_materials,
            active_theme,
        );
        content_y = new_clone_y + new_clone_icon_size + ui_gap * 4;
    }
    // ── Two columns extending down from below the summary line. ──

    // Left column: stats (flush left, top-aligned at content_y).
    const stat_font_size: i32 = 64;
    const stat_line_height: i32 = stat_font_size + ui_gap;
    const stat_entries = [_]struct { label: []const u8, value: u32 }{
        .{ .label = "Turns Spent", .value = info.turns_spent },
        .{ .label = "Tiles Moved", .value = info.tiles_moved },
        .{ .label = "Skills Used", .value = info.skills_used },
        .{ .label = "Damage Dealt", .value = info.damage_dealt },
        .{ .label = "Damage Taken", .value = info.damage_taken },
    };
    const stats_left = screen.x + ui_gap * 4;
    var stat_y = content_y;
    for (stat_entries) |entry| {
        const value_text = try std.fmt.allocPrint(allocator, "{d}", .{entry.value});
        const line_text = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ entry.label, value_text });
        try elements.append(allocator, .{ .text_label = .{
            .text = line_text,
            .screen_position = .{ .x = stats_left, .y = stat_y },
            .font_size = stat_font_size,
            .blocks_input = false,
        } });
        stat_y += stat_line_height;
    }

    // ── Right column (flush right, top-aligned at content_y) — branch by
    //    context. ──
    const material_right = screen.x + screen.width - ui_gap * 4;
    if (validation) |context| {
        // The medal ladder, Trackmania-style: the Author row is the
        // author's own validated turns — the SAME value the targets derive
        // from (the replay file's turns; this run's as the fallback when
        // no replay landed). Derived at display time, never stored. See
        // DESIGN → Custom Missions & Online Services → Turn counters +
        // author medals.
        const medal_lines = [_]struct { label: []const u8, turns: u32 }{
            .{ .label = "Author", .turns = context.personal_best_turns orelse info.turns_spent },
            .{ .label = "Gold", .turns = context.medal_targets.gold },
            .{ .label = "Silver", .turns = context.medal_targets.silver },
            .{ .label = "Bronze", .turns = context.medal_targets.bronze },
        };
        var medal_y = content_y;
        for (medal_lines) |medal_line| {
            const medal_line_text = try std.fmt.allocPrint(
                allocator,
                "{s}: {d} turns",
                .{ medal_line.label, medal_line.turns },
            );
            const medal_line_width = font_metrics.measureSpanWidth(text(medal_line_text), stat_font_size);
            try elements.append(allocator, .{ .text_label = .{
                .text = medal_line_text,
                .screen_position = .{ .x = material_right - medal_line_width, .y = medal_y },
                .font_size = stat_font_size,
                .blocks_input = false,
            } });
            medal_y += stat_line_height;
        }
    } else {
        // "Clone material harvest" sub-header + vertical material icon
        // stack.
        const harvest_header_font_size: i32 = 64;
        const harvest_header_text = "Clone material harvest";
        const harvest_header_width = font_metrics.measureSpanWidth(text(harvest_header_text), harvest_header_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = harvest_header_text,
            .screen_position = .{ .x = material_right - harvest_header_width, .y = content_y },
            .font_size = harvest_header_font_size,
            .blocks_input = false,
        } });
        const icon_top = content_y + harvest_header_font_size + ui_gap * 2;
        try emitMaterialIcons(
            elements,
            allocator,
            font_metrics,
            .{ .x = material_right - inventory_slot_size, .y = icon_top },
            inventory_slot_size,
            .vertical,
            info.harvested_materials,
            active_theme,
        );
    }

    // ── Bottom buttons — branch by context. Continue always sits in the
    //    bottom-right corner; the left button + the conditional centered
    //    button differ. ──
    const buttons_row = screen.placeBottomCenter(menu_button_width, panel_button_height, ui_gap * 4);
    const button_y = buttons_row.y;
    const margin = ui_gap * 4;
    if (validation) |context| {
        // Validate Again — bottom-left. The same action as the top-bar
        // Validate button: the dispatch saves first, then starts the run
        // (the overlay disappears on the level transition — start_validation
        // retires the stats info).
        try emitPanelButton(elements, allocator, font_metrics, .{
            .x = screen.x + margin,
            .y = button_y,
            .width = menu_button_width,
            .height = panel_button_height,
        }, "Validate Again", menu_button_font_size, .validate_editor_mission, button_color, null);
        // Continue — bottom-right.
        try emitPanelButton(elements, allocator, font_metrics, .{
            .x = screen.x + screen.width - margin - menu_button_width,
            .y = button_y,
            .width = menu_button_width,
            .height = panel_button_height,
        }, "Continue", menu_button_font_size, .continue_after_mission, button_color, null);
        // Overwrite Replay — centered, only while the personal-best guard
        // kept the old file and this slower run's slice is stashed. Writes
        // the STASHED bytes (a session-side side effect, no recorded event).
        if (context.overwrite_offered) {
            const centered = screen.placeBottomCenter(menu_button_width, panel_button_height, ui_gap * 4);
            try emitPanelButton(elements, allocator, font_metrics, centered, "Overwrite Replay", menu_button_font_size, .overwrite_validation_replay, button_color, null);
        }
    } else {
        // Replay Mission — bottom-left.
        try emitPanelButton(elements, allocator, font_metrics, .{
            .x = screen.x + margin,
            .y = button_y,
            .width = menu_button_width,
            .height = panel_button_height,
        }, "Replay Mission", menu_button_font_size, .replay_mission, button_color, null);
        // Continue — bottom-right.
        try emitPanelButton(elements, allocator, font_metrics, .{
            .x = screen.x + screen.width - margin - menu_button_width,
            .y = button_y,
            .width = menu_button_width,
            .height = panel_button_height,
        }, "Continue", menu_button_font_size, .continue_after_mission, button_color, null);
        // Overwrite Clone — centered (only when offered).
        if (info.overwrite_offered) {
            const centered = screen.placeBottomCenter(menu_button_width, panel_button_height, ui_gap * 4);
            try emitPanelButton(elements, allocator, font_metrics, centered, "Overwrite Clone", menu_button_font_size, .overwrite_clone, button_color, null);
        }
    }
}

/// Build the mission-fail overlay: a full-screen 9-slice panel with a
/// large "Defeat" label centered above a two-button stack (Restart
/// Mission / Exit Mission — named for the editor RUN while one is active:
/// Restart/Exit Playtest or Validation). Rendered when the player is dead
/// (derived from `level.entities[0].current_health == 0` in view()). The
/// buttons reuse the existing `.restart_mission` / `.exit_mission`
/// actions — same dispatch path as the options menu. See DESIGN →
/// Architecture.
pub fn buildMissionFail(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    /// The active editor run, if any (.playtest / .validate) — same role
    /// as in `buildOptionsMenu`.
    editor_run: ?types.EditorMode,
    button_color: Color,
) !void {
    // Full-screen panel background.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
    } });

    const defeat_font_size: i32 = 256;
    const defeat_label_width = font_metrics.measureSpanWidth(text("Defeat"), defeat_font_size);
    const defeat_label = screen.placeCenter(defeat_label_width, defeat_font_size);
    // Place the label above the button stack, leaving room for the buttons
    // and a gap between the label and the stack.
    const buttons_above: i32 = 2 * panel_button_height + ui_gap;
    try elements.append(allocator, .{ .text_label = .{
        .text = "Defeat",
        .screen_position = .{
            .x = defeat_label.x,
            .y = defeat_label.y - buttons_above - ui_gap - defeat_font_size,
        },
        .font_size = defeat_font_size,
        .blocks_input = false,
    } });

    const MenuButton = struct { label: []const u8, action: Action };
    const run_noun: []const u8 = if (editor_run) |run_mode| switch (run_mode) {
        .playtest => "Playtest",
        .validate => "Validation",
        .edit => "Mission",
    } else "Mission";
    const buttons = [_]MenuButton{
        .{ .label = try std.fmt.allocPrint(allocator, "Restart {s}", .{run_noun}), .action = .restart_mission },
        .{ .label = try std.fmt.allocPrint(allocator, "Exit {s}", .{run_noun}), .action = .exit_mission },
    };

    const total_height = rowWidth(@intCast(buttons.len), panel_button_height, ui_gap);
    const origin = screen
        .placeCenter(menu_button_width, total_height)
        .position();

    for (buttons, 0..) |menu_button, index| {
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
            null,
        );
    }
}

test "buildErrorPopup emits a modal panel, header, body, and a Dismiss button" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, "failed to parse data/campaigns/act_one.txt: missing Campaign section", .{ .r = 50, .g = 50, .b = 50 });

    // Panel + header label(s) + body label(s) + (panel + button + label) from emitPanelButton.
    // At minimum: 1 nine_slice (popup) + 1 header text + N body texts + 1 nine_slice (button) + 1 button + 1 label.
    try std.testing.expect(elements.items.len >= 6);

    // The first element is the popup panel and it is modal (blocks_input).
    try std.testing.expectEqual(std.meta.activeTag(elements.items[0]), .nine_slice_panel);
    try std.testing.expect(elements.items[0].nine_slice_panel.blocks_input);

    // The Dismiss button carries Action.dismiss_error.
    var found_dismiss = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .dismiss_error) {
            found_dismiss = true;
        },
        else => {},
    };
    try std.testing.expect(found_dismiss);
}

test "buildErrorPopup: short message — no scrollbar, scroll offset clamped to 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};
    session.error_scroll_offset = 500; // should be clamped to 0 (content fits)

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, "short error", .{ .r = 50, .g = 50, .b = 50 });

    // No scrollbar (no solid_rect) since content fits in the visible region.
    for (elements.items) |element| switch (element) {
        .solid_rect => @panic("unexpected scrollbar for short message"),
        else => {},
    };
    try std.testing.expectEqual(@as(i32, 0), session.error_scroll_offset);
}

test "buildErrorPopup: long message — scrollbar present, only visible lines emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};

    // Build a message long enough to overflow error_popup_max_body_height:
    // the 40-char-token shape from the scrolled-window test (exactly 60
    // visual lines — one token per line at these metrics; a '\n' does NOT
    // break lines, wrapRow only breaks on width).
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(std.testing.allocator);
    for (0..60) |i| {
        if (i > 0) msg.appendSlice(std.testing.allocator, " ") catch @panic("msg");
        msg.print(std.testing.allocator, "L{d:0>39}", .{i}) catch @panic("msg");
    }

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, msg.items, .{ .r = 50, .g = 50, .b = 50 });

    // Scrollbar present (at least 2 solid_rects: track + thumb).
    var solid_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .solid_rect => solid_count += 1,
        else => {},
    };
    try std.testing.expect(solid_count >= 2);

    // Scroll offset is 0 (top of content) since we didn't scroll.
    try std.testing.expectEqual(@as(i32, 0), session.error_scroll_offset);
}

test "buildErrorPopup: scrolled window renders at the body top" {
    // The regression this pins: the old pixel-offset view drew the window's
    // lines at their UNSCROLLED y (blank space above, bottom lines
    // overflowing the panel) — "scrolls but renders the wrong text, cut
    // off weirdly". The window's first line must render AT the body
    // region's top, and be the offset'th line of the message.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};
    session.error_scroll_offset = 10; // first visible line = line 10

    // 60 space-separated 40-char tokens ("L" + zero-padded index). At these
    // metrics each token is 40×28 = 1120px — it fits the 1216px wrap limit
    // alone, but two can never share a line (1120+28+1120 > 1216) — so the
    // message wraps to EXACTLY 60 visual lines, one span (one label) each,
    // with deterministic content per line. (A '\n' in the message does NOT
    // break lines — wrapRow only breaks on width, at spaces and '/'.)
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(std.testing.allocator);
    for (0..60) |i| {
        if (i > 0) msg.appendSlice(std.testing.allocator, " ") catch @panic("msg");
        msg.print(std.testing.allocator, "L{d:0>39}", .{i}) catch @panic("msg");
    }

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, msg.items, .{ .r = 50, .g = 50, .b = 50 });

    // Collect the body labels (font_size == error_body_font_size). One
    // label per visual line at these metrics (single-span lines).
    var body_labels: usize = 0;
    var first_body: ?text_label_attrs = null;
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (label.font_size == error_body_font_size) {
            if (first_body == null) first_body = .{
                .text = label.text,
                .y = label.screen_position.y,
            };
            body_labels += 1;
        },
        else => {},
    };

    // Whole visible lines only: min(60, 1600 / 67) = 23.
    const expected_visible: usize = @min(
        @as(usize, 60),
        @as(usize, @intCast(@divTrunc(error_popup_max_body_height, lineHeight(error_body_font_size)))),
    );
    try std.testing.expectEqual(expected_visible, body_labels);

    // The first visible line is line 10 of the message...
    const first = first_body orelse return error.TestUnexpectedResult;
    var expected_text: std.ArrayList(u8) = .empty;
    defer expected_text.deinit(std.testing.allocator);
    try expected_text.print(std.testing.allocator, "L{d:0>39}", .{10});
    try std.testing.expectEqualStrings(expected_text.items, first.text);

    // ...and it renders AT the body region's top: panel top + padding +
    // header lines + header gap (the header "Error" wraps to 1 line here).
    const panel = elements.items[0].nine_slice_panel;
    const expected_body_top = panel.screen_position.y +
        error_popup_padding +
        lineHeight(error_header_font_size) +
        error_header_gap;
    try std.testing.expectEqual(expected_body_top, first.y);

    // The offset stays 10 — well within max_scroll (60 - 23 = 37 lines of
    // scroll available); only out-of-range offsets clamp.
    try std.testing.expectEqual(@as(i32, 10), session.error_scroll_offset);
}

test "buildErrorPopup: newline-separated warnings render as distinct lines" {
    // The startup warnings are joined with '\n' (session_setup). The
    // measurement/rendering contract: wrapRow breaks on '\n' and never
    // emits it inside a span — because raylib's DrawTextEx ALSO breaks on
    // '\n', with its own line advance + x reset that the layout never
    // reserved space for. Before the fix, the '\n' rode inside a word
    // token: raylib drew a second line at y+fontSize+textLineSpacing that
    // overlapped the next visual row at y+lineHeight — "lines overlap each
    // other, layout weird".
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};

    // Two warnings, each short enough to be one visual line (no width wrap).
    const message = "InputBindings entry for 'skill_slot_1' is missing a valid context\nInputBindings entry for 'skill_slot_2' is missing a valid context";

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, message, .{ .r = 50, .g = 50, .b = 50 });

    // Collect the body labels' distinct y positions (word-level spans share
    // a y) and assert no label text carries a newline.
    var first_y: ?i32 = null;
    var second_y: ?i32 = null;
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (label.font_size == error_body_font_size) {
            try std.testing.expect(std.mem.indexOfScalar(u8, label.text, '\n') == null);
            const y = label.screen_position.y;
            if (first_y == null) {
                first_y = y;
            } else if (second_y == null and y != first_y.?) {
                second_y = y;
            }
        },
        else => {},
    };

    // Two visual lines, one per warning, exactly one lineHeight apart.
    try std.testing.expect(first_y != null);
    try std.testing.expect(second_y != null);
    try std.testing.expectEqual(lineHeight(error_body_font_size), second_y.? - first_y.?);
}

const text_label_attrs = struct {
    text: []const u8,
    y: i32,
};

test "buildErrorPopup: scroll offset clamped to max_scroll on long message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};
    session.error_scroll_offset = 100_000; // way past max_scroll (lines)

    // The same 60-token message (exactly 60 visual lines — one token
    // per line at these metrics).
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(std.testing.allocator);
    for (0..60) |i| {
        if (i > 0) msg.appendSlice(std.testing.allocator, " ") catch @panic("msg");
        msg.print(std.testing.allocator, "L{d:0>39}", .{i}) catch @panic("msg");
    }

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, msg.items, .{ .r = 50, .g = 50, .b = 50 });

    // Clamped to exactly max_scroll: the line count minus the visible
    // count (derived from the popup's own constants, the same shape as the
    // scrolled-window test).
    const expected_visible: i32 = @intCast(@divTrunc(error_popup_max_body_height, lineHeight(error_body_font_size)));
    try std.testing.expectEqual(@as(i32, 60) - expected_visible, session.error_scroll_offset);
}

const testing = std.testing;

fn missionCompleteDummyTheme() types.ActiveColorTheme {
    return .{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .enemy_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .player_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
    };
}

const MissionCompleteScan = struct {
    header_validated: bool = false,
    header_completed: bool = false,
    author_line: bool = false,
    gold_line: bool = false,
    silver_line: bool = false,
    bronze_line: bool = false,
    medal_header: bool = false,
    new_clone_label: bool = false,
    harvest_header: bool = false,
    validate_again_button: bool = false,
    replay_mission_button: bool = false,
    continue_button: bool = false,
    overwrite_replay_button: bool = false,
    overwrite_clone_button: bool = false,

    fn scan(elements: []const ui_element.UiElement) MissionCompleteScan {
        var found: MissionCompleteScan = .{};
        for (elements) |element| switch (element) {
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "New Mission validated")) found.header_validated = true;
                if (std.mem.eql(u8, label.text, "New Mission completed")) found.header_completed = true;
                if (std.mem.eql(u8, label.text, "Author medals")) found.medal_header = true;
                if (std.mem.eql(u8, label.text, "Author: 3 turns")) found.author_line = true;
                if (std.mem.eql(u8, label.text, "Gold: 4 turns")) found.gold_line = true;
                if (std.mem.eql(u8, label.text, "Silver: 6 turns")) found.silver_line = true;
                if (std.mem.eql(u8, label.text, "Bronze: 15 turns")) found.bronze_line = true;
                if (std.mem.eql(u8, label.text, "New clone:")) found.new_clone_label = true;
                if (std.mem.eql(u8, label.text, "Clone material harvest")) found.harvest_header = true;
            },
            .button => |button| switch (button.action) {
                .validate_editor_mission => found.validate_again_button = true,
                .replay_mission => found.replay_mission_button = true,
                .continue_after_mission => found.continue_button = true,
                .overwrite_validation_replay => found.overwrite_replay_button = true,
                .overwrite_clone => found.overwrite_clone_button = true,
                else => {},
            },
            else => {},
        };
        return found;
    }
};

test "buildMissionComplete: the validation variant swaps the clone content for medals + Validate Again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildMissionComplete(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        .{ .name = "New Mission", .path = "missions/x", .turns_spent = 4, .validation = true },
        missionCompleteDummyTheme(),
        .{
            .personal_best_turns = 3,
            // medalTargets(3): gold = ceil(3.6) = 4, silver = 6, bronze = 15.
            .medal_targets = validation_replay.medalTargets(3),
            .overwrite_offered = true,
        },
    );

    const found = MissionCompleteScan.scan(elements.items);
    // The validation surface: "validated" header, the medal ladder
    // (Author crowning the derived targets — pb 3 → gold 4 / silver 6 /
    // bronze 15), Validate Again / Continue / the offered Overwrite
    // Replay.
    try testing.expect(found.header_validated);
    try testing.expect(found.author_line);
    try testing.expect(found.gold_line);
    try testing.expect(found.silver_line);
    try testing.expect(found.bronze_line);
    try testing.expect(found.validate_again_button);
    try testing.expect(found.continue_button);
    try testing.expect(found.overwrite_replay_button);
    // NO campaign content: no clone summary/harvest, no Replay Mission, no
    // Overwrite Clone, no leftover column header.
    try testing.expect(!found.header_completed);
    try testing.expect(!found.new_clone_label);
    try testing.expect(!found.harvest_header);
    try testing.expect(!found.medal_header);
    try testing.expect(!found.replay_mission_button);
    try testing.expect(!found.overwrite_clone_button);
}

test "buildMissionComplete: the campaign variant is unchanged (regression)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildMissionComplete(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        .{ .name = "New Mission", .path = "missions/x", .turns_spent = 4, .overwrite_offered = true },
        missionCompleteDummyTheme(),
        null,
    );

    const found = MissionCompleteScan.scan(elements.items);
    // The campaign surface: "completed" header, clone summary + harvest,
    // Replay Mission / Continue / the offered Overwrite Clone.
    try testing.expect(found.header_completed);
    try testing.expect(found.new_clone_label);
    try testing.expect(found.harvest_header);
    try testing.expect(found.replay_mission_button);
    try testing.expect(found.continue_button);
    try testing.expect(found.overwrite_clone_button);
    // NO validation content.
    try testing.expect(!found.header_validated);
    try testing.expect(!found.author_line);
    try testing.expect(!found.medal_header);
    try testing.expect(!found.validate_again_button);
    try testing.expect(!found.overwrite_replay_button);
}
