//! The tips overlay: the full-screen `?` surface with prose tip + nav
//! (data/tips.txt content - DESIGN → UI Framework → Tips overlay). One of
//! menus.zig's per-surface splits.

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
const panel_button_height = ui_element.panel_button_height;
const credits = @import("credits.zig");
const credits_header_font_size = credits.credits_header_font_size;
const credits_padding = credits.credits_padding;
const credits_button_width = credits.credits_button_width;
const menu_button_font_size = ui_element.menu_button_font_size;
const lineHeight = ui_element.lineHeight;
const spanRow = @import("tooltip.zig").spanRow;

// --- Tips overlay (full screen, any screen) ---

const tips_body_font_size: i32 = 96;
/// The n/N ordinal under the header.
const tips_count_font_size: i32 = 64;
/// Gap between the text column and the flanking nav buttons.
const tips_nav_gap: i32 = 96;
const tips_glyph_font_size: i32 = 64;
const top_bar_slot_size = ui_element.top_bar_slot_size;
const wrapRow = ui_element.wrapRow;

/// Build the tips overlay: a full-screen modal (the credits model) with a
/// centered half-width text column showing ONE tip at a time (wrapped),
/// 128x128 prev/next glyph buttons flanking the column, and a Back button
/// in the credits position. The viewed tip index is a view affordance on
/// `SessionState.ui_state.tips_index` (the settings_tab convention - off
/// the undo timeline; the `cycle_tips` action mutates it at the input
/// layer). Pure over `GameState.ui_surfaces.isSurfaceOpen(.tips)` + the
/// session's tips list + index. See DESIGN → UI Framework.
pub fn buildTipsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    tips: []const []const u8,
    viewed_tip_index: usize,
    active_theme: types.ActiveColorTheme,
    button_color: Color,
) !void {
    // Full-screen modal background - blocks input to everything behind it
    // (the world, bars, panels, and the options menu it can open on top
    // of - only the global top bar draws above it).
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    // Header, centered horizontally near the top (the credits model).
    const header_text = "Tips";
    const header_width = font_metrics.measureSpanWidth(text(header_text), credits_header_font_size);
    const header_x = screen.x + @divTrunc(screen.width - header_width, 2);
    const header_y = screen.y + credits_padding;
    try elements.append(allocator, .{ .text_label = .{
        .text = header_text,
        .screen_position = .{ .x = header_x, .y = header_y },
        .font_size = credits_header_font_size,
        .blocks_input = false,
    } });

    // Back button, bottom-left (the credits position). Reuses the
    // toggle_tips toggle - Back = close (the credits Back pattern).
    const button_y = screen.y + screen.height - credits_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = screen.x + credits_padding,
            .y = button_y,
            .width = credits_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .toggle_tips,
        button_color,
        null,
    );

    // An empty tips list (a modded-but-valid file): nothing to show or
    // cycle - the panel is the background + header + Back alone.
    if (tips.len == 0) return;

    // The viewed tip, wrapped to the column. The index is clamped here -
    // a stale index beyond a shrunk list renders the last tip, never
    // crashes (the bounds-checked convention of the inspect target).
    const safe_index = @min(viewed_tip_index, tips.len - 1);

    // The viewed tip's ordinal (n/N), centered directly beneath the
    // header - part of the content (the empty-list degradation shows no
    // counter).
    const header_bottom = header_y + lineHeight(credits_header_font_size);
    const count_text = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ safe_index + 1, tips.len });
    const count_width = font_metrics.measureSpanWidth(text(count_text), tips_count_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = count_text,
        .screen_position = .{ .x = screen.x + @divTrunc(screen.width - count_width, 2), .y = header_bottom },
        .font_size = tips_count_font_size,
        .blocks_input = false,
    } });

    const column_width = @divTrunc(screen.width, 2);
    const column_x = screen.x + @divTrunc(screen.width - column_width, 2);
    const body_lines = try wrapRow(
        allocator,
        font_metrics,
        try spanRow(allocator, text(tips[safe_index])),
        tips_body_font_size,
        column_width,
    );
    const body_line_height = lineHeight(tips_body_font_size);
    const body_height: i32 = @intCast(body_lines.len * @as(usize, @intCast(body_line_height)));

    // Vertically center the text block in the space between the counter
    // and the Back button (the credits block-centering model).
    const count_bottom = header_bottom + lineHeight(tips_count_font_size);
    const content_center_y = count_bottom + @divTrunc(button_y - count_bottom, 2);
    const body_top = content_center_y - @divTrunc(body_height, 2);

    var y = body_top;
    for (body_lines) |line| {
        var x = column_x;
        for (line) |span| {
            try elements.append(allocator, .{ .text_label = .{
                .text = span.text,
                .screen_position = .{ .x = x, .y = y },
                .color = span.color,
                .font_size = tips_body_font_size,
                .blocks_input = false,
            } });
            x += font_metrics.measureSpanWidth(span, tips_body_font_size);
        }
        y += body_line_height;
    }

    // Prev/next: 128x128 glyph buttons flanking the column, vertically
    // centered on the content area (the top-bar button treatment - small
    // background sprite + font glyph, tinted like the top bar's buttons).
    const p = active_theme.player_gradient.colors;
    const nav_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const nav_glyph = p[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const nav_y = content_center_y - @divTrunc(top_bar_slot_size, 2);
    const previous_cell = Rectangle{
        .x = column_x - tips_nav_gap - top_bar_slot_size,
        .y = nav_y,
        .width = top_bar_slot_size,
        .height = top_bar_slot_size,
    };
    const next_cell = Rectangle{
        .x = column_x + column_width + tips_nav_gap,
        .y = nav_y,
        .width = top_bar_slot_size,
        .height = top_bar_slot_size,
    };
    try emit.emitGlyphIconButton(
        elements,
        allocator,
        font_metrics,
        previous_cell,
        "<",
        tips_glyph_font_size,
        .cycle_tips,
        .{ .tips_direction = .previous },
        .{ .header = try spanRow(allocator, text("Previous tip")) },
        nav_bg,
        nav_glyph,
    );
    try emit.emitGlyphIconButton(
        elements,
        allocator,
        font_metrics,
        next_cell,
        ">",
        tips_glyph_font_size,
        .cycle_tips,
        .{ .tips_direction = .next },
        .{ .header = try spanRow(allocator, text("Next tip")) },
        nav_bg,
        nav_glyph,
    );
}
