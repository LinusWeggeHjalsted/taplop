//! The credits screen: the full-panel credit roll + back button (DESIGN →
//! UI Framework). One of menus.zig's per-surface splits.

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
const rowWidth = ui_element.rowWidth;
const panel_button_height = ui_element.panel_button_height;
const menu_button_font_size = ui_element.menu_button_font_size;
const lineHeight = ui_element.lineHeight;

// --- Credits screen (main menu, full screen) ---

/// Full-screen page header font size - pub for the tips overlay (the
/// same page model: centered header, page padding, wide bottom button).
pub const credits_header_font_size: i32 = 96;
/// Name line font size - larger than the roles line so each person reads
/// as a heading above their credits.
const credits_name_font_size: i32 = 72;
/// Roles line font size - the credit detail under each name.
const credits_role_font_size: i32 = 48;
/// Gap between a person's name and their roles line.
const credits_name_to_role_gap: i32 = 16;
/// Gap between each person block (name + roles).
const credits_person_gap: i32 = 64;
pub const credits_padding: i32 = 48;
const credits_button_gap: i32 = 48;
/// Back button size (bottom-left). Matches the load-save Back button so the
/// two main-menu overlays feel consistent.
pub const credits_button_width: i32 = 768;

/// Build the credits screen: a full-screen modal panel with a centered
/// "Credits" header, three person blocks (name in a larger font above their
/// roles in a smaller font, gaps between each person), and a Back button in
/// the bottom-left. The panel blocks input to the main-menu buttons behind
/// it. The Back button reuses the `.open_credits` action (toggle semantics -
/// same pattern as the load-save browser's Back button).
pub fn buildCreditsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
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
