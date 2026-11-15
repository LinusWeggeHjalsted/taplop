//! The hub editor's UI surface (the slice-4 drill-in - DESIGN → Campaigns
//! & the Campaign Editor → The hub editor surface): the level-editor
//! mirror over one hub's grid. This file owns the always-present
//! structural UI (the top bar's return button; the tool palette,
//! inspector, and metadata sidebar land with the editing slices, each
//! mirroring its src/ui/ sibling of the mission editor). The world scene
//! (tiles + spawn + NPCs + exit markers + decorations over the hub grid)
//! lives in view.zig with the other world drawable builders.
//! See DESIGN → Campaigns & the Campaign Editor → The hub editor surface.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const editor_shell = @import("editor_shell.zig");
const emit = @import("emit.zig");
const ui_tooltip = @import("tooltip.zig");

const UiElementList = ui_element.UiElementList;
const Rectangle = types.Rectangle;
const Color = types.Color;
const spanRow = ui_tooltip.spanRow;
const text = ui_element.text;

/// The hub editor's top-right primary action: the world-map RETURN button
/// (back to the campaign map - the drill-in's exit; navigation is
/// side-effect-free, the settled no-autosave rule). The mission editor's
/// `buildEditorPrimaryActions` icon-button class at its cell exactly
/// (flush against the right screen edge); the icon is placeholder art
/// until an asset lands (the icon_playtest/validate precedent - the art
/// report carries it automatically). Slice 5's mission-editor
/// world-map button (the campaign-context return) is the same button
/// concept and will reuse this builder's shape.
pub fn buildHubEditorTopBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    // Match the top-bar options/undo buttons: background = gradient[5],
    // icon = gradient[1] (the editor primary-actions treatment).
    const c_btn_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_btn_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const return_cell: Rectangle = .{
        .x = types.reference_width - ui_element.top_bar_slot_size,
        .y = 0,
        .width = ui_element.top_bar_slot_size,
        .height = ui_element.top_bar_slot_size,
    };

    try emit.emitIconButton(
        elements,
        allocator,
        return_cell,
        emit.small_button_background_sprite_id,
        "ui/icon_world_map",
        .close_hub_editor,
        .{ .header = try spanRow(allocator, text("Return to the campaign map")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );
}

// ============================================================
// Structure tests - predicate scans (the campaign editor's test
// conventions).
// ============================================================

test "buildHubEditorTopBar: one world-map return button flush top-right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    const test_theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = @splat(black) },
    };

    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    try buildHubEditorTopBar(&elements, arena.allocator(), test_theme);

    var found: ?ui_element.Button = null;
    var button_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            button_count += 1;
            if (button.action == .close_hub_editor) found = button;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), button_count);
    const button = found orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(types.reference_width - ui_element.top_bar_slot_size, button.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), button.screen_position.y);
    try std.testing.expectEqual(ui_element.top_bar_slot_size, button.width);
    try std.testing.expect(button.tooltip != null);
}
