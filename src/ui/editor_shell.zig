//! Editor shell: the tool palette (bottom bar with fixed tools +
//! palette groups + add-new "+" cells), the level tab row, and the
//! Test/Validate primary actions - plus the shared editor layout
//! constants and the palette group math used by the input-side wheel
//! routing. The inspector/metadata sidebar live in editor_inspector.zig,
//! the centered pickers in editor_pickers.zig.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const ui_state_mod = @import("state.zig");

const Action = types.Action;
const ScreenPosition = types.ScreenPosition;
const Row = ui_element.Row;
const Rectangle = types.Rectangle;
const Color = types.Color;
const UiState = ui_state_mod.UiState;
const Span = ui_element.Span;
const Tooltip = ui_element.Tooltip;
const TooltipRow = ui_element.TooltipRow;
const text = ui_element.text;
const colored = ui_element.colored;
const bold = ui_element.bold;
const FontMetrics = ui_element.FontMetrics;
const UiElement = ui_element.UiElement;
const UiElementList = ui_element.UiElementList;
const Button = ui_element.Button;
const Image = ui_element.Image;
const Slot = ui_element.Slot;
const slot_size = ui_element.slot_size;
const top_bar_slot_size = ui_element.top_bar_slot_size;
const ui_gap = ui_element.ui_gap;
const slot_padding = ui_element.slot_padding;
const small_icon_size = ui_element.small_icon_size;
const default_tint = ui_element.default_tint;
const emitIconButton = emit.emitIconButton;
const emitPanelButton = emit.emitPanelButton;
const emitPanelHeader = emit.emitPanelHeader;
const emitMaterialIcons = emit.emitMaterialIcons;
const material_count_font_size = emit.material_count_font_size;
const material_count_inset = emit.material_count_inset;
const itemIconSpriteId = emit.itemIconSpriteId;
const inventory_slot_size = ui_element.inventory_slot_size;
const screenRect = ui_element.screenRect;
const bottom_bar_height = ui_element.bottom_bar_height;
const close_button_sprite_id = ui_element.close_button_sprite_id;
const close_button_size = ui_element.close_button_size;
const button_background_sprite_id = emit.button_background_sprite_id;
const small_button_background_sprite_id = emit.small_button_background_sprite_id;
const spanRow = @import("tooltip.zig").spanRow;

/// All entity sprites share one 512x640 frame - the canonical constants
/// live in types.zig (`types.entity_sprite_frame_*`). Duplicated here
/// because src/ui/ can't import view.zig (view imports the
/// ui facade).
pub const editor_entity_frame_width: i32 = types.entity_sprite_frame_width;
pub const editor_entity_frame_height: i32 = types.entity_sprite_frame_height;

/// Native size of the square tile-class tool graphics (the `world/tile`
/// sprite; the Select tool's fitted square too). The retired
/// `world/tile_highlight.png` marching-ants sheet shared the size - the
/// Select graphic is now the inset stroked square (see the fixed-tools
/// emission).
const tool_graphic_tile_size: i32 = 256;

/// Font size for the editor palette group headers ("Entities", ...).
pub const editor_group_header_font_size: i32 = 64;

/// Height of the group header buttons and the editor "+" cells: 128.
/// Expanded groups' headers sit in a strip above the bar; collapsed
/// groups' headers + "+" sit flush against the bottom of the screen
/// (see `buildEditorBottomBar`).
pub const editor_header_strip_height: i32 = 128;

/// Side length of the square ui/panel "+" cells (palette group add-new,
/// level-tab add-level).
pub const editor_plus_size: i32 = 128;

/// Maximum type cells a palette group shows at once. Groups with more
/// types scroll horizontally (wheel over the group shifts the window;
/// see `UiState.editor_palette_scroll`).
pub const editor_palette_max_tools: usize = 8;

/// A palette group's type count: 0 = Entities, 1 = Decorations, 2 = Ground
/// Items. Shared between the builder's window math and the wheel routing's
/// emission-order segmentation.
pub fn editorPaletteGroupSize(editor: types.Editor, group_index: usize) usize {
    return switch (group_index) {
        0 => editor.entity_types.len,
        1 => editor.decoration_types.len,
        else => editor.item_types.len,
    };
}

/// Which editor palette group's tool cells contain `position`, if any.
/// Tool cells are Buttons whose sprite is `ui/button_background` (the
/// header buttons are spriteless over panels and the "+" cells are
/// panels - neither matches), so detection matches those in the
/// bottom-bar band and
/// segments the emission order: 2 fixed tools, then per EXPANDED group
/// `min(size, max_tools)` type cells (collapsed groups contribute none).
/// Valid only on the editor screen; callers gate on it.
pub fn editorPaletteGroupAt(
    editor: types.Editor,
    collapsed: [3]bool,
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?usize {
    if (position.y < types.reference_height - bottom_bar_height) return null;
    var cell_index: usize = 0;
    for (ui_elements) |element| switch (element) {
        .button => |button| {
            const sprite_id = button.sprite_id orelse continue;
            if (!std.mem.eql(u8, sprite_id, button_background_sprite_id)) continue;
            if (button.screen_position.y < types.reference_height - bottom_bar_height) continue;
            defer cell_index += 1;
            const group = editorPaletteGroupOfCell(editor, collapsed, cell_index) orelse continue;
            const cell: Rectangle = .{
                .x = button.screen_position.x,
                .y = button.screen_position.y,
                .width = button.width,
                .height = button.height,
            };
            if (cell.contains(position)) return group;
        },
        else => {},
    };
    return null;
}

/// Map a flat tool-cell index (bottom-bar emission order) to its palette
/// group. The first 2 cells are the fixed tools (Select, Tile); each
/// EXPANDED group then contributes `min(size, max_tools)` type cells
/// (collapsed groups contribute none).
fn editorPaletteGroupOfCell(editor: types.Editor, collapsed: [3]bool, cell_index: usize) ?usize {
    var index = cell_index;
    if (index < 2) return null;
    index -= 2;
    for (0..3) |group_index| {
        if (collapsed[group_index]) continue;
        const segment = @min(
            editorPaletteGroupSize(editor, group_index),
            editor_palette_max_tools,
        );
        if (index < segment) return group_index;
        index -= segment;
    }
    return null;
}

/// Largest aspect-preserving rectangle that fits inside `cell`, centered.
/// Non-positive sprite dimensions (an unresolvable/missing sprite) fall
/// back to the full cell so the renderer's missing-art magenta still shows
/// at cell size.
pub fn scaleToFit(cell: Rectangle, sprite_width: i32, sprite_height: i32) Rectangle {
    if (sprite_width <= 0 or sprite_height <= 0) return cell;
    const scale = @min(
        @as(f32, @floatFromInt(cell.width)) / @as(f32, @floatFromInt(sprite_width)),
        @as(f32, @floatFromInt(cell.height)) / @as(f32, @floatFromInt(sprite_height)),
    );
    const fitted_width: i32 = @intFromFloat(@as(f32, @floatFromInt(sprite_width)) * scale);
    const fitted_height: i32 = @intFromFloat(@as(f32, @floatFromInt(sprite_height)) * scale);
    return cell.placeCenter(fitted_width, fitted_height);
}

/// The button layer of an editor tool cell: a `ui/button_background`
/// Button tinted as a button (player gradient index 5) carrying the tool's
/// action + payload + tooltip. Selecting the tool makes it active; the
/// ACTIVE tool's button is highlighted (lightest edge outline), as is the
/// hovered one via the generic hover pass in `view()`. The cell's graphic
/// (one image or a composed stack) is emitted on top by the caller -
/// graphics pass hover through to the button (`blocks_input = false`).
fn emitEditorToolCellButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    tool: types.EditorToolId,
    button_color: Color,
    tooltip_header: []const u8,
    active_tool: types.EditorToolId,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = button_background_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = .select_editor_tool,
        .payload = .{ .editor_tool = tool },
        .color = button_color,
        .highlighted = std.meta.eql(tool, active_tool),
        .tooltip = .{ .header = try spanRow(allocator, text(tooltip_header)) },
    } });
}

/// Emit one editor tool cell: a `ui/button_background` Button tinted as a
/// button (player gradient index 5) carrying the tool's action + payload +
/// tooltip + input, with the tool's graphic scaled to fit (aspect-preserved,
/// centered, then multiplied by `graphic_scale`) on top - the icon passes
/// hover through to the button. Selecting the tool makes it active; the
/// ACTIVE tool's button is highlighted (lightest edge outline), as is the
/// hovered one via the generic hover pass in `view()`.
fn emitEditorToolCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    tool: types.EditorToolId,
    graphic_sprite_id: []const u8,
    graphic_width: i32,
    graphic_height: i32,
    graphic_scale: f32,
    graphic_color: Color,
    button_color: Color,
    tooltip_header: []const u8,
    active_tool: types.EditorToolId,
) !void {
    try emitEditorToolCellButton(
        elements,
        allocator,
        cell,
        tool,
        button_color,
        tooltip_header,
        active_tool,
    );
    // Fit the graphic at native dims, then shrink the fitted rect by
    // `graphic_scale`. (Scaling the INPUT dims is a no-op - scaleToFit
    // grows or shrinks to fill the cell, so the aspect ratio erases any
    // uniform pre-scale.)
    const fitted_full = scaleToFit(cell, graphic_width, graphic_height);
    const fitted_width: i32 = @intFromFloat(@as(f32, @floatFromInt(fitted_full.width)) * graphic_scale);
    const fitted_height: i32 = @intFromFloat(@as(f32, @floatFromInt(fitted_full.height)) * graphic_scale);
    const fitted = cell.placeCenter(fitted_width, fitted_height);
    try elements.append(allocator, .{ .image = .{
        .sprite_id = graphic_sprite_id,
        .screen_position = fitted.position(),
        .width = fitted.width,
        .height = fitted.height,
        .color = graphic_color,
        .blocks_input = false,
    } });
}

/// One non-blocking image of a composed palette-cell graphic, drawn at the
/// precomputed fitted rect (all images of one cell share it - entity +
/// decoration art stacks are same-frame overlays, so they must land
/// pixel-identical to each other like they do in the scene).
fn appendCellGraphicImage(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    sprite_id: []const u8,
    fitted: Rectangle,
    color: Color,
    flip_horizontal: bool,
) !void {
    try elements.append(allocator, .{ .image = .{
        .sprite_id = sprite_id,
        .screen_position = fitted.position(),
        .width = fitted.width,
        .height = fitted.height,
        .color = color,
        .flip_horizontal = flip_horizontal,
        .blocks_input = false,
    } });
}

/// Emit an ENTITY palette tool cell: the tool button + the entity's scene
/// composition at cell scale - base sprite, then overlay layers, then
/// weapons (main hand as-authored, off hand mirrored), all sharing one
/// fitted rect because entity art shares the 512x640 frame + pivot. Tints
/// follow `entityDrawable` (view.zig): base + layers at their own
/// color_index into the team gradient - or UNTINTED when
/// `keep_original_colors` is set - and weapons at team gradient index 1
/// (our art, always themed); weapons are suppressed when
/// `displays_weapons` is false (e.g. wolves).
fn emitEditorEntityToolCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    tool: types.EditorToolId,
    template: types.Entity,
    team_gradient: [types.gradient_color_count]types.Color,
    button_color: Color,
    tooltip_header: []const u8,
    active_tool: types.EditorToolId,
) !void {
    try emitEditorToolCellButton(
        elements,
        allocator,
        cell,
        tool,
        button_color,
        tooltip_header,
        active_tool,
    );
    const fitted = scaleToFit(cell, editor_entity_frame_width, editor_entity_frame_height);

    // Base + layers untinted (pure white) when keep_original_colors is
    // set - the art keeps its own colors; weapons below stay themed.
    const base_sprite_id = try std.fmt.allocPrint(allocator, "entities/{s}", .{template.sprite});
    const base_color_index = @min(template.color_index, types.gradient_color_count - 1);
    const base_color = if (template.keep_original_colors)
        default_tint
    else
        team_gradient[base_color_index];
    try appendCellGraphicImage(
        elements,
        allocator,
        base_sprite_id,
        fitted,
        base_color,
        false,
    );

    for (template.layers) |layer| {
        const layer_sprite_id = try std.fmt.allocPrint(allocator, "entities/{s}", .{layer.sprite});
        const layer_color_index = @min(layer.color_index, types.gradient_color_count - 1);
        const layer_color = if (template.keep_original_colors)
            default_tint
        else
            team_gradient[layer_color_index];
        try appendCellGraphicImage(
            elements,
            allocator,
            layer_sprite_id,
            fitted,
            layer_color,
            false,
        );
    }

    if (template.displays_weapons) {
        // Team 0 bodies wield the plain weapon art; enemy silhouettes the
        // enemy_ variant - the scene's weaponSprite rule.
        const variant_prefix = if (template.team == 0) "" else "enemy_";
        const weapon_color = team_gradient[1];
        if (template.main_hand_weapon) |weapon| {
            const sprite_id = try std.fmt.allocPrint(
                allocator,
                "weapons/{s}{s}",
                .{ variant_prefix, @tagName(weapon.weapon_type) },
            );
            try appendCellGraphicImage(elements, allocator, sprite_id, fitted, weapon_color, false);
        }
        if (template.off_hand_weapon) |weapon| {
            const sprite_id = try std.fmt.allocPrint(
                allocator,
                "weapons/{s}{s}",
                .{ variant_prefix, @tagName(weapon.weapon_type) },
            );
            try appendCellGraphicImage(elements, allocator, sprite_id, fitted, weapon_color, true);
        }
    }
}

/// Emit a DECORATION palette tool cell: the tool button + the decoration's
/// scene composition at cell scale - base sprite, then overlay layers, all
/// sharing one fitted rect (layers are validated to match the base's pixel
/// dims, so one fit covers the whole stack). Tints follow the scene's
/// decoration pass: base + layers at their own color_index into the world
/// gradient - or UNTINTED when `keep_original_colors` is set.
fn emitEditorDecorationToolCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    tool: types.EditorToolId,
    type_definition: types.DecorationTypeDef,
    world_gradient: [types.gradient_color_count]types.Color,
    button_color: Color,
    tooltip_header: []const u8,
    active_tool: types.EditorToolId,
) !void {
    try emitEditorToolCellButton(
        elements,
        allocator,
        cell,
        tool,
        button_color,
        tooltip_header,
        active_tool,
    );
    const fitted = scaleToFit(cell, type_definition.pixel_dims.x, type_definition.pixel_dims.y);

    // Base + layers untinted (pure white) when keep_original_colors is
    // set - the art keeps its own colors.
    const base_sprite_id = try std.fmt.allocPrint(allocator, "decorations/{s}", .{type_definition.sprite});
    const base_color_index = @min(type_definition.color_index, types.gradient_color_count - 1);
    const base_color = if (type_definition.keep_original_colors)
        default_tint
    else
        world_gradient[base_color_index];

    // The scene's draw order (draw.zig): back layers (`behind`), then the
    // base, then overlay layers - element order in the flat list.
    for (type_definition.layers) |layer| {
        if (!layer.behind) continue;
        try appendDecorationLayerCellImage(
            elements,
            allocator,
            layer,
            fitted,
            type_definition.keep_original_colors,
            world_gradient,
        );
    }
    try appendCellGraphicImage(
        elements,
        allocator,
        base_sprite_id,
        fitted,
        base_color,
        false,
    );
    for (type_definition.layers) |layer| {
        if (layer.behind) continue;
        try appendDecorationLayerCellImage(
            elements,
            allocator,
            layer,
            fitted,
            type_definition.keep_original_colors,
            world_gradient,
        );
    }
}

/// One decoration layer's image in a palette tool cell (the fitted rect
/// shared with the base - layers match the base's pixel dims). Tinted with
/// the layer's own color_index into the world gradient, or untinted when
/// the type keeps its original colors.
fn appendDecorationLayerCellImage(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    layer: types.DecorationLayer,
    fitted: Rectangle,
    keep_original_colors: bool,
    world_gradient: [types.gradient_color_count]types.Color,
) !void {
    const layer_sprite_id = try std.fmt.allocPrint(allocator, "decorations/{s}", .{layer.sprite});
    const layer_color_index = @min(layer.color_index, types.gradient_color_count - 1);
    const layer_color = if (keep_original_colors)
        default_tint
    else
        world_gradient[layer_color_index];
    try appendCellGraphicImage(
        elements,
        allocator,
        layer_sprite_id,
        fitted,
        layer_color,
        false,
    );
}

/// The small delete button flush in a palette tool cell's top-right corner
/// - the shared close-button visual (`close_button_sprite_id`, the picker
/// panel / in-game middle-panel close class). Deletes the tool's palette
/// type + every placement referencing it across all levels
/// (`.delete_editor_palette_type`); the cell's tool rides the
/// `editor_tool` payload. Emitted AFTER the tool cell so hit-testing
/// (last-wins) prefers it where the two overlap.
fn emitEditorToolDeleteButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    tool: types.EditorToolId,
    type_name: []const u8,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = close_button_sprite_id,
        .screen_position = .{
            .x = cell.x + cell.width - close_button_size,
            .y = cell.y,
        },
        .width = close_button_size,
        .height = close_button_size,
        .action = .delete_editor_palette_type,
        .payload = .{ .editor_tool = tool },
        .tooltip = .{ .header = try spanRow(allocator, text(
            try std.fmt.allocPrint(allocator, "Delete {s} + its placements", .{type_name}),
        )) },
    } });
}

fn editorLevelTabsLeft(editor: types.Editor) i32 {
    const leading_cells: i32 = if (editor.campaign_mission != null) 4 else 3;
    return leading_cells * (top_bar_slot_size + ui_gap);
}

/// Editor top row: level tabs, emitted to the RIGHT of the global top
/// bar's occupied leading cells (those come from `buildGlobalTopBar` - the
/// always-on-top layer; the tabs deliberately stay UNDER overlays). The
/// campaign hand-off's map-return cell shifts the row one cell right;
/// standalone missions start immediately after redo. One 128-high
/// panel-backed button per level (the
/// palette group-header visual class), labeled with the level's name or
/// "Level N" if unnamed. The ACTIVE tab is highlighted (lightest edge
/// outline - the same path as tool cells); clicking switches the active
/// level (payload = level index → `.select_editor_level` →
/// `player_set_editor_level`, which rides the undo timeline). Each tab
/// carries a small close-button (the shared `ui/close_button` class) flush
/// in its top-right corner - `.delete_editor_level` deletes the level;
/// offered only while the mission has more than one level (a mission
/// always keeps ≥1). The row is bounded on the right by the primary-actions
/// block (Test + Validate); when the tabs overflow it, the row shows a
/// scroll window (one wheel notch over the tabs = one tab; the builder
/// clamps both bounds and keeps the ACTIVE tab on-screen). The square
/// panel "+" (`.add_editor_level`) pins flush at the row's right edge so
/// it stays reachable while scrolled: append a new level from the shipped
/// template (data/default_level.txt) + switch to it. See DESIGN →
/// Architecture → Level Editor → Editor UI layout (tabs).
pub fn buildEditorLevelTabs(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    ui_state: *UiState,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // Tabs start right of the global top bar's occupied leading cells
    // (options + undo + redo, plus the campaign-map return when present;
    // the trailing ui_gap separates the tabs), flush against the top of the
    // screen, and end at the pinned add-level "+" - one ui_gap clear of it,
    // one clear of the primary-actions block.
    const region_left = editorLevelTabsLeft(editor);
    const plus_cell: Rectangle = .{
        .x = types.reference_width - editor_primary_actions_width - ui_gap -
            editor_header_strip_height,
        .y = 0,
        .width = editor_header_strip_height,
        .height = editor_header_strip_height,
    };
    const tabs_right_bound: i32 = plus_cell.x - ui_gap;
    const region_width: i32 = tabs_right_bound - region_left;

    // Per-tab labels + widths, computed up front: the scroll clamp and the
    // active-tab follow below need every width before anything is emitted.
    const TabLayout = struct { label: []const u8, width: i32 };
    const tabs = try allocator.alloc(TabLayout, editor.levels.len);
    const delete_zone_width: i32 = if (editor.levels.len > 1)
        close_button_size + ui_gap
    else
        0;
    for (editor.levels, 0..) |level, index| {
        const label = if (level.name.len > 0)
            level.name
        else
            try std.fmt.allocPrint(allocator, "Level {d}", .{index + 1});
        const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
        // The × delete button clears the label by WIDENING the tab: the
        // label centers in the zone left of the × (its width + one
        // ui_gap), so the two can never overlap. Width never drops below
        // the tab height (a square floor so short labels don't squish the
        // panel).
        tabs[index] = .{
            .label = label,
            .width = @max(
                label_width + delete_zone_width + 2 * ui_gap,
                editor_header_strip_height,
            ),
        };
    }

    // Scroll clamp (authoritative, in place - the builder knows the tab
    // widths): the max offset is the smallest offset whose remaining tab
    // suffix fits the region; scrolling past it would only hide tabs at
    // the front. Capped at the last tab so a tab wider than the whole
    // region can't blank the row (it renders width-clamped as the first
    // visible tab below).
    const scroll_offset = &ui_state.editor_level_tab_scroll;
    {
        var suffix_width: i32 = 0;
        var smallest_fitting: usize = editor.levels.len;
        while (smallest_fitting > 0) {
            const add: i32 = tabs[smallest_fitting - 1].width +
                (if (smallest_fitting < editor.levels.len) ui_gap else 0);
            if (suffix_width + add > region_width) break;
            suffix_width += add;
            smallest_fitting -= 1;
        }
        const max_offset: usize = @min(smallest_fitting, editor.levels.len - 1);
        scroll_offset.* = @min(@max(scroll_offset.*, 0), @as(i32, @intCast(max_offset)));
    }

    // Active-tab follow - ONLY on a change of the active tab (tracked via
    // `editor_level_tab_last_active`): the add-level flow switches to the
    // newly created LAST tab ("the author lands on the thing they just
    // created"), which a scrolled window would hide. Firing on every
    // frame would snap the window back to the active tab and make manual
    // scrolling impossible, so the follow scrolls the minimum distance
    // that brings the active tab into the window exactly once per change
    // - never past the clamp above.
    const active = @min(editor.active_level_index, editor.levels.len - 1);
    if (ui_state.editor_level_tab_last_active != @as(i32, @intCast(active))) {
        const first: usize = @intCast(scroll_offset.*);
        if (active < first) {
            scroll_offset.* = @intCast(active);
        } else {
            var used: i32 = 0;
            var last_visible: usize = first;
            for (tabs[first..], first..) |tab, index| {
                if (index > first and used + tab.width > region_width) break;
                used += tab.width + ui_gap;
                last_visible = index;
            }
            if (active > last_visible) {
                // Walk backward from the active tab: the smallest offset
                // whose window still contains it.
                var back: usize = active;
                var back_used: i32 = tabs[active].width;
                while (back > first) {
                    const add = tabs[back - 1].width + ui_gap;
                    if (back_used + add > region_width) break;
                    back_used += add;
                    back -= 1;
                }
                scroll_offset.* = @intCast(back);
            }
        }
        ui_state.editor_level_tab_last_active = @intCast(active);
    }

    // Emit the visible window: fully-fitting tabs only (the palette
    // window model - offscreen tabs can't be clicked). The FIRST visible
    // tab always renders, its width clamped to the region.
    const first_visible: usize = @intCast(scroll_offset.*);
    var x = region_left;
    const y: i32 = 0;
    for (tabs[first_visible..], first_visible..) |tab, index| {
        if (index > first_visible and x + tab.width > tabs_right_bound) break;
        const width: i32 = if (index == first_visible)
            @min(tab.width, tabs_right_bound - x)
        else
            tab.width;
        const label = tab.label;
        const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
        const cell: Rectangle = .{
            .x = x,
            .y = y,
            .width = width,
            .height = editor_header_strip_height,
        };

        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = cell.position(),
            .width = width,
            .height = editor_header_strip_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = cell.position(),
            .width = width,
            .height = editor_header_strip_height,
            .action = .select_editor_level,
            .payload = .{ .editor_level = @intCast(index) },
            .highlighted = index == editor.active_level_index,
        } });
        try elements.append(allocator, .{
            .text_label = .{
                .text = label,
                // Centered in the zone LEFT of the delete button, not the
                // full tab - the × owns the top-right corner.
                .screen_position = .{
                    .x = cell.x + @divFloor(width - delete_zone_width - label_width, 2),
                    .y = cell.y + @divFloor(
                        cell.height - editor_group_header_font_size,
                        2,
                    ),
                },
                .font_size = editor_group_header_font_size,
                .color = active_theme.lightest,
                .blocks_input = false,
            },
        });
        // The tab's × (delete level): the shared close-button visual, flush
        // in the tab's top-right corner, emitted AFTER the tab so hit-
        // testing (last-wins) prefers it where the two overlap. Offered
        // only while the mission has more than one level - a mission
        // always keeps ≥1 (the handler enforces it as its invariant).
        if (editor.levels.len > 1) {
            try elements.append(allocator, .{ .button = .{
                .sprite_id = close_button_sprite_id,
                .screen_position = .{
                    .x = cell.x + width - close_button_size,
                    .y = cell.y,
                },
                .width = close_button_size,
                .height = close_button_size,
                .action = .delete_editor_level,
                .payload = .{ .editor_level = @intCast(index) },
                .tooltip = .{ .header = try spanRow(allocator, text("Delete level")) },
            } });
        }

        x += width + ui_gap;
    }

    // Add-level "+": square panel cell PINNED flush at the row's right
    // edge (always reachable while the tab window scrolls) - a BUTTON
    // (spriteless over the panel, the group-header class):
    // `.add_editor_level` appends the template level + switches to it.
    try emitEditorPlusCell(
        elements,
        allocator,
        font_metrics,
        plus_cell,
        button_color,
        active_theme.lightest,
        "Add Level",
        .add_editor_level,
        null,
    );
}

/// The top-right primary-actions block's total width (Test + Validate:
/// two `slot_size` cells + the separating gap). Shared by the buttons
/// builder, the level-tab row's right bound, and the tab wheel-scroll
/// region so the three can't drift.
const editor_primary_actions_width: i32 = 2 * top_bar_slot_size + ui_gap;

/// The level-tab strip's wheel-scroll region: from the tab row's left
/// edge (right of the global top bar's occupied leading cells) to the
/// primary-actions block, top-aligned with the tabs. One wheel notch over
/// it scrolls the tab window by one tab (`UiState.editor_level_tab_scroll`).
pub fn editorLevelTabScrollRegion(editor: types.Editor) Rectangle {
    const left = editorLevelTabsLeft(editor);
    return .{
        .x = left,
        .y = 0,
        .width = types.reference_width - editor_primary_actions_width - left,
        .height = editor_header_strip_height,
    };
}

/// The editor's primary actions (top-right corner): the Test button (a
/// single-level playtest of the active level) and the Validate button (a
/// full-mission validation run from level 1). The options/undo icon class
/// (`emitIconButton`: button background + icon, `slot_size` square) at the
/// top bar's height, flush against the right screen edge - the visual
/// mirror of options/undo at the top-left. The icon sprites
/// (`ui/icon_playtest`, `ui/icon_validate`) are placeholder art until
/// assets land. See DESIGN → Architecture → Level Editor → Editor UI
/// layout (primary actions).
pub fn buildEditorPrimaryActions(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    // Match the top-bar options/undo buttons: background = gradient[5],
    // icon = gradient[1].
    const c_btn_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_btn_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    // Flush right, reading left-to-right: Test, then Validate. The
    // block's total width is `editor_primary_actions_width` - the shared
    // bound the level-tab row clamps against.
    const validate_cell: Rectangle = .{
        .x = types.reference_width - top_bar_slot_size,
        .y = 0,
        .width = top_bar_slot_size,
        .height = top_bar_slot_size,
    };
    const test_cell: Rectangle = .{
        .x = validate_cell.x - top_bar_slot_size - ui_gap,
        .y = 0,
        .width = top_bar_slot_size,
        .height = top_bar_slot_size,
    };

    try emitIconButton(
        elements,
        allocator,
        test_cell,
        small_button_background_sprite_id,
        "ui/icon_playtest",
        .test_editor_level,
        .{ .header = try spanRow(allocator, text("Test (play the active level)")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );
    try emitIconButton(
        elements,
        allocator,
        validate_cell,
        small_button_background_sprite_id,
        "ui/icon_validate",
        .validate_editor_mission,
        .{ .header = try spanRow(allocator, text("Validate (play the whole mission)")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );
}

/// Editor bottom bar: the tool palette. Fixed tools first
/// (Select, Tile), then three groups - Entities, Decorations, Items -
/// each a header toggle + a square panel "+" (add-new) cell + one slot per
/// palette type. Expanded groups put their header + "+" in the strip above
/// the bar; collapsed (or empty) groups put them flush against the bottom
/// of the screen. Every tool renders the shared button background plus a
/// distinguishing graphic: Select = the inset square outline (the
/// clickable-tile highlight's look - see the fixed-tools emission), Tile =
/// `world/tile`, entities + decorations = their FULL scene composition
/// (base + layers, plus weapons for entities - off-hand mirrored,
/// suppressed when `displays_weapons` is false), each layer tinted exactly
/// as `entityDrawable` / the decoration pass tints them (see DESIGN →
/// Entity & UI Coloring), so the palette preview matches what a placement
/// looks like in the viewport; ground items = the item icon (ground items
/// always render as the shared ground bag in-world, so the palette shows
/// the ITEM's icon for authoring distinction). Interaction is wired: tool
/// cells make themselves the active tool (`player_set_editor_tool`),
/// headers toggle collapse, and the "+" cells append a new type from the
/// shipped defaults (`player_add_editor_*_type`) - the entity/decoration
/// ones also open the base-sprite picker. Horizontal
/// scrolling: a group shows at most `editor_palette_max_tools` type cells;
/// `scroll_offsets[group]` (clamped in place here to `[0, size - max]`) is
/// the first visible cell, and the wheel scrolls the window while the
/// pointer is over the group (see `editorPaletteGroupAt`). See DESIGN →
/// Architecture → Level Editor → Editor UI layout (tool palette).
pub fn buildEditorBottomBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    scroll_offsets: *[3]i32,
    collapsed: *[3]bool,
    active_tool: types.EditorToolId,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_icon_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const world = active_theme.world_gradient.colors;
    const enemy = active_theme.enemy_gradient.colors;

    const group_labels = [_][]const u8{ "Entities", "Decorations", "Items" };
    // The groups' "+" add-new tooltips (singular, tool-shaped - the
    // labels are plural group names).
    const group_plus_tooltips = [_][]const u8{ "Add Entity Tool", "Add Decoration Tool", "Add Item Tool" };
    const group_sizes = [3]usize{
        editor.entity_types.len,
        editor.decoration_types.len,
        editor.item_types.len,
    };

    // Per-group header button widths (label + side padding).
    var header_widths: [group_labels.len]i32 = undefined;
    for (group_labels, 0..) |label, group_index| {
        header_widths[group_index] =
            font_metrics.measureSpanWidth(text(label), editor_group_header_font_size) + 2 * ui_gap;
    }

    // Row footprint per group: expanded = its visible type cells;
    // collapsed (or empty) = the header + "+" extent. The header-to-"+"
    // gap is INCLUDED in that extent, so the row's join gap stays a real
    // gap AFTER the "+" (not eaten by it) - and an expanded group whose
    // cells are narrower than its header + "+" (a 1-2-type group) takes
    // the extent as its footprint, so the "+" can't overlap the next
    // group's header in the strip above. Total content width joins the
    // footprints by ui_gap.
    var footprints: [group_labels.len]i32 = undefined;
    var content_width: i32 = 2 * slot_size; // Select + Tile
    for (group_sizes, 0..) |size, group_index| {
        const header_plus_extent = header_widths[group_index] + ui_gap + editor_plus_size;
        if (collapsed[group_index] or size == 0) {
            footprints[group_index] = header_plus_extent;
        } else {
            const visible: i32 = @intCast(@min(size, editor_palette_max_tools));
            const cells_width = visible * slot_size + (visible - 1) * ui_gap;
            footprints[group_index] = @max(cells_width, header_plus_extent);
        }
        content_width += footprints[group_index];
    }
    content_width += (2 + group_labels.len - 1) * ui_gap;

    // The bar is flush against the screen's LEFT edge (not centered): the
    // content width changes as groups expand/collapse, and centering would
    // move the fixed tools - left-anchoring keeps Select/Tile stable.
    const bar = screen.placeBottomLeft(content_width, bottom_bar_height, 0);
    var row = Row.init(bar.position(), bottom_bar_height, ui_gap);

    // Fixed tools. The tile graphic draws at half size (the tile art is
    // busy at full cell scale).
    //
    // Select: the clickable-tile highlight's look - an inset square
    // outline, inset by the shared `tile_highlight_inset_divisor` (the
    // prototype sheet's band position) with the CONSTANT outline-class
    // stroke (types.outline_thickness, independent of the cell size). A
    // stroked solid_rect IS the outline class, so it draws through the
    // stripe shader - the icon animates exactly like the world highlight.
    {
        const cell = row.next(slot_size);
        try emitEditorToolCellButton(
            elements,
            allocator,
            cell,
            .select,
            button_color,
            "Select",
            active_tool,
        );
        const fitted = scaleToFit(cell, tool_graphic_tile_size, tool_graphic_tile_size);
        const inset = @divTrunc(fitted.width, ui_element.tile_highlight_inset_divisor);
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = fitted.x + inset, .y = fitted.y + inset },
            .width = fitted.width - 2 * inset,
            .height = fitted.height - 2 * inset,
            .color = active_theme.lightest,
            .filled = false,
            .line_width = types.outline_thickness,
            .blocks_input = false,
        } });
    }
    try emitEditorToolCell(
        elements,
        allocator,
        row.next(slot_size),
        .tile,
        "world/tile",
        tool_graphic_tile_size,
        tool_graphic_tile_size,
        0.5,
        world[@min(@as(u32, 1), types.gradient_color_count - 1)],
        button_color,
        "Tile paint",
        active_tool,
    );

    // Palette groups. Each group emits: a header toggle button + a "+"
    // button (square ui/panel cells, same visual class as the level tabs)
    // and its visible window of type cells in the row (none when
    // collapsed). An EXPANDED group's header + "+" sit in the strip above
    // the bar - even when the group is EMPTY (the header rises on expand,
    // consistently, instead of staying pinned to the bottom edge); a
    // COLLAPSED group has no cells to label, so it drops flush against
    // the bottom of the screen instead of hovering above the bar. The
    // footprint math keeps its own `or size == 0` (an empty group has no
    // cells to size, so its row extent is just the header + "+").
    for (group_labels, 0..) |label, group_index| {
        const size = group_sizes[group_index];
        const group_left = bar.x + row.cursor_x;
        const footprint = footprints[group_index];
        const header_y: i32 = if (collapsed[group_index])
            screen.bottom() - editor_header_strip_height
        else
            bar.y - ui_gap - editor_header_strip_height;

        // Header: panel-backed button (128 high), left-aligned with the
        // group. Clicking toggles collapse (payload = group index).
        const header_width = header_widths[group_index];
        const header_cell: Rectangle = .{
            .x = group_left,
            .y = header_y,
            .width = header_width,
            .height = editor_header_strip_height,
        };
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = header_cell.position(),
            .width = header_width,
            .height = editor_header_strip_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = header_cell.position(),
            .width = header_width,
            .height = editor_header_strip_height,
            .action = .toggle_editor_palette_group,
            .payload = .{ .editor_group = group_index },
        } });
        const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = header_cell.placeCenter(label_width, editor_group_header_font_size).position(),
            .font_size = editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });

        // "+" (add-new): square ui/panel cell one ui_gap right of the
        // header (adjacent - reads as tied to the group; the gap keeps
        // the two cells visually distinct), carrying the add-new action
        // + the group index payload. The handler builds the type from
        // the shipped defaults, makes it the active tool, and opens the
        // inspector; the input layer opens the sprite picker for enemies
        // + decorations.
        const plus_cell: Rectangle = .{
            .x = group_left + header_width + ui_gap,
            .y = header_y,
            .width = editor_plus_size,
            .height = editor_plus_size,
        };
        try emitEditorPlusCell(
            elements,
            allocator,
            font_metrics,
            plus_cell,
            button_color,
            active_theme.lightest,
            group_plus_tooltips[group_index],
            .add_editor_palette_type,
            group_index,
        );

        // Type cells: the visible window (skipped entirely when collapsed).
        if (!collapsed[group_index] and size > 0) {
            // Clamp the window offset in place (authoritative - the wheel
            // handler also bounds-checks, but the builder owns the truth).
            const max_offset: i32 = @intCast(size -| editor_palette_max_tools);
            scroll_offsets[group_index] = @min(@max(scroll_offsets[group_index], 0), max_offset);
            const first_visible: usize = @intCast(scroll_offsets[group_index]);
            const visible = @min(size, editor_palette_max_tools);

            switch (group_index) {
                0 => for (editor.entity_types[first_visible .. first_visible + visible], 0..) |type_definition, ordinal| {
                    // The team gradient at the template's color_index - a
                    // team-0 type is a player-team helper and tints with the
                    // player gradient (DESIGN → Entity & UI Coloring).
                    const team_gradient = if (type_definition.template.team == 0) p else enemy;
                    try emitEditorEntityToolCell(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .entity_type = @intCast(first_visible + ordinal) },
                        type_definition.template,
                        team_gradient,
                        button_color,
                        type_definition.id,
                        active_tool,
                    );
                    try emitEditorToolDeleteButton(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .entity_type = @intCast(first_visible + ordinal) },
                        type_definition.id,
                    );
                },
                1 => for (editor.decoration_types[first_visible .. first_visible + visible], 0..) |type_definition, ordinal| {
                    try emitEditorDecorationToolCell(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .decoration_type = @intCast(first_visible + ordinal) },
                        type_definition,
                        world,
                        button_color,
                        type_definition.id,
                        active_tool,
                    );
                    try emitEditorToolDeleteButton(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .decoration_type = @intCast(first_visible + ordinal) },
                        type_definition.id,
                    );
                },
                else => for (editor.item_types[first_visible .. first_visible + visible], 0..) |type_definition, ordinal| {
                    try emitEditorToolCell(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .item_type = @intCast(first_visible + ordinal) },
                        itemIconSpriteId(type_definition.item),
                        inventory_slot_size,
                        inventory_slot_size,
                        1.0,
                        item_icon_color,
                        button_color,
                        type_definition.id,
                        active_tool,
                    );
                    try emitEditorToolDeleteButton(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .item_type = @intCast(first_visible + ordinal) },
                        type_definition.id,
                    );
                },
            }
        }

        // Advance the row cursor past the group's footprint + inter-group
        // gap (explicit - groups don't use `Row.next`, whose per-cell
        // trailing gap would double the inter-group spacing).
        row.cursor_x += footprint + ui_gap;
    }
}

/// The nth tool cell of a palette group starting at `group_left`.
fn cellAt(bar_y: i32, group_left: i32, ordinal: usize) Rectangle {
    const offset: i32 = @intCast(ordinal);
    return .{
        .x = group_left + offset * (slot_size + ui_gap),
        .y = bar_y,
        .width = slot_size,
        .height = bottom_bar_height,
    };
}

/// A square ui/panel "+" cell (the editor's add-new affordance - palette
/// group pluses and the level-tab add-level plus): a panel + a spriteless
/// button over it (the group-header class) carrying the tooltip + a
/// centered "+" glyph. `cell` should be square. The tooltip rides the
/// BUTTON, not the panel - hitTest halts at the first blocking element,
/// so a panel-level tooltip would be shielded by the button covering it.
fn emitEditorPlusCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    panel_color: Color,
    text_color: Color,
    tooltip_header: []const u8,
    action: types.Action,
    editor_group: ?usize,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = panel_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = null,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = action,
        .payload = if (editor_group) |group_index|
            .{ .editor_group = group_index }
        else
            null,
        .tooltip = .{ .header = try spanRow(allocator, text(tooltip_header)) },
    } });
    const plus_width = font_metrics.measureSpanWidth(text("+"), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = "+",
        .screen_position = cell.placeCenter(plus_width, editor_group_header_font_size).position(),
        .font_size = editor_group_header_font_size,
        .color = text_color,
        .blocks_input = false,
    } });
}

test "scaleToFit: aspect-preserved, centered, degenerate dims fall back to cell" {
    const cell = Rectangle{ .x = 100, .y = 200, .width = 256, .height = 256 };

    // Tall sprite (the 512x640 entity frame): height-limited → 204x256,
    // centered horizontally.
    const tall = scaleToFit(cell, 512, 640);
    try std.testing.expectEqual(@as(i32, 204), tall.width);
    try std.testing.expectEqual(@as(i32, 256), tall.height);
    try std.testing.expectEqual(@as(i32, 100 + 26), tall.x);
    try std.testing.expectEqual(@as(i32, 200), tall.y);

    // Wide sprite (e.g. a 768x512 decoration): width-limited → 256x170.
    const wide = scaleToFit(cell, 768, 512);
    try std.testing.expectEqual(@as(i32, 256), wide.width);
    try std.testing.expectEqual(@as(i32, 170), wide.height);

    // Unresolvable dims (a fresh type with no sprite yet) → the full cell.
    const degenerate = scaleToFit(cell, 0, 0);
    try std.testing.expectEqual(cell, degenerate);
}

test "buildEditorLevelTabs: one panel button per level, active highlighted, unnamed fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const player_one: types.Color = .{ .r = 30, .g = 30, .b = 30 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = .{ black, player_one, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    const levels = [_]types.EditorLevel{
        .{ .name = "The Crossing" },
        .{}, // unnamed -> "Level 2"
        .{}, // unnamed -> "Level 3"
    };
    const editor: types.Editor = .{
        .levels = &levels,
        .active_level_index = 1,
    };

    var elements: UiElementList = .empty;
    var ui_state: UiState = .{ .editor_level_tab_scroll = 999 };
    try buildEditorLevelTabs(&elements, arena.allocator(), metrics, editor, theme, &ui_state);

    // No overflow: the scroll clamps to 0 (authoritative in the builder).
    try std.testing.expectEqual(@as(i32, 0), ui_state.editor_level_tab_scroll);

    // 3 tabs x (panel + spriteless button + label + × button) + the
    // add-level "+" (panel + button + glyph) = 15 elements.
    try std.testing.expectEqual(@as(usize, 15), elements.items.len);

    // In the standalone editor, tabs sit right of the global top bar's
    // options + undo + redo cells, 128 high, flush against the top.
    const start_x = 3 * (top_bar_slot_size + ui_gap);
    try std.testing.expectEqual(@as(i32, start_x), elements.items[0].nine_slice_panel.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), elements.items[0].nine_slice_panel.screen_position.y);
    try std.testing.expectEqual(@as(i32, 128), elements.items[0].nine_slice_panel.height);
    try std.testing.expectEqual(start_x, editorLevelTabScrollRegion(editor).x);

    // Per tab: the button carries the payload + action; only the ACTIVE
    // tab (index 1) is highlighted. Labels: the level's name, else
    // "Level N".
    const expected_labels = [_][]const u8{ "The Crossing", "Level 2", "Level 3" };
    var previous_x: i32 = start_x;
    for (0..3) |tab| {
        const button = elements.items[4 * tab + 1].button;
        try std.testing.expectEqual(Action.select_editor_level, button.action);
        try std.testing.expectEqual(@as(u32, @intCast(tab)), button.payload.?.editor_level);
        try std.testing.expectEqual(tab == 1, button.highlighted);
        try std.testing.expect(button.sprite_id == null); // spriteless over the panel

        const label = elements.items[4 * tab + 2].text_label;
        try std.testing.expectEqualStrings(expected_labels[tab], label.text);
        try std.testing.expect(!label.blocks_input);

        // The tab's × (offered while the mission has >1 level): the shared
        // close-button visual, flush in the tab's top-right corner,
        // carrying the tab's index.
        const close_button = elements.items[4 * tab + 3].button;
        try std.testing.expectEqual(Action.delete_editor_level, close_button.action);
        try std.testing.expectEqualStrings(close_button_sprite_id, close_button.sprite_id.?);
        try std.testing.expectEqual(@as(u32, @intCast(tab)), close_button.payload.?.editor_level);
        try std.testing.expectEqual(close_button_size, close_button.width);
        try std.testing.expectEqual(@as(i32, 0), close_button.screen_position.y);
        const tab_panel = elements.items[4 * tab].nine_slice_panel;
        try std.testing.expectEqual(
            tab_panel.screen_position.x + tab_panel.width - close_button_size,
            close_button.screen_position.x,
        );
        // The widened tab: the label sits fully clear of the ×'s zone
        // (centered in the area left of it - the tab grew by exactly
        // that zone's width; at least a full ui_gap of clearance).
        try std.testing.expect(
            label.screen_position.x + metrics.measureSpanWidth(
                text(expected_labels[tab]),
                editor_group_header_font_size,
            ) <= close_button.screen_position.x - ui_gap,
        );

        // Tabs lay out left-to-right, advancing past each panel.
        const panel_x = elements.items[4 * tab].nine_slice_panel.screen_position.x;
        try std.testing.expect(panel_x >= previous_x);
        previous_x = panel_x;
    }

    // Add-level "+": square ui/panel cell to the right of the last tab,
    // top-aligned with the tabs - a BUTTON (spriteless over the panel)
    // carrying the tooltip: `.add_editor_level` appends the template
    // level. The tooltip rides the button, not the panel - hitTest halts
    // at the first blocking element, so a panel-level tooltip would be
    // shielded by the button covering it.
    const plus_panel = elements.items[12].nine_slice_panel;
    try std.testing.expectEqualStrings("ui/panel", plus_panel.sprite_id);
    try std.testing.expectEqual(@as(i32, 128), plus_panel.width);
    try std.testing.expectEqual(@as(i32, 128), plus_panel.height);
    try std.testing.expectEqual(@as(i32, 0), plus_panel.screen_position.y);
    try std.testing.expect(plus_panel.screen_position.x > previous_x);
    try std.testing.expect(plus_panel.tooltip == null);
    const plus_button = elements.items[13].button;
    try std.testing.expectEqual(Action.add_editor_level, plus_button.action);
    try std.testing.expect(plus_button.sprite_id == null);
    try std.testing.expectEqualStrings(
        "Add Level",
        plus_button.tooltip.?.header.?[0].text,
    );
    try std.testing.expectEqualStrings("+", elements.items[14].text_label.text);
    try std.testing.expect(!elements.items[14].text_label.blocks_input);

    // A single-level mission offers NO × (a mission always keeps ≥1 level
    // - the delete gate): one tab x (panel + button + label) + the "+"
    // trio = 6 elements.
    {
        var single_elements: UiElementList = .empty;
        var single_ui_state: UiState = .{};
        const single_levels = [_]types.EditorLevel{.{ .name = "Only" }};
        const single_editor: types.Editor = .{ .levels = &single_levels };
        try buildEditorLevelTabs(&single_elements, arena.allocator(), metrics, single_editor, theme, &single_ui_state);
        try std.testing.expectEqual(@as(usize, 6), single_elements.items.len);
        var close_button_count: usize = 0;
        for (single_elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .delete_editor_level) close_button_count += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 0), close_button_count);
    }

    // The campaign hand-off reserves the map-return cell too: its first tab
    // starts one cell later, with the usual gap after the return button.
    // The pinned right side stays fixed, so the scroll region narrows by the
    // same stride. Standalone missions retain the original boundary above.
    {
        const campaign_editor: types.Editor = .{
            .campaign_mission = 0,
            .levels = &levels,
            .active_level_index = 1,
        };
        var campaign_elements: UiElementList = .empty;
        var campaign_ui_state: UiState = .{};
        try buildEditorLevelTabs(&campaign_elements, arena.allocator(), metrics, campaign_editor, theme, &campaign_ui_state);

        const stride = top_bar_slot_size + ui_gap;
        const campaign_start_x = 4 * stride;
        try std.testing.expectEqual(campaign_start_x, campaign_elements.items[0].nine_slice_panel.screen_position.x);
        const return_cell_right = 3 * stride + top_bar_slot_size;
        try std.testing.expectEqual(ui_gap, campaign_start_x - return_cell_right);

        const standalone_scroll_region = editorLevelTabScrollRegion(editor);
        const campaign_scroll_region = editorLevelTabScrollRegion(campaign_editor);
        try std.testing.expectEqual(campaign_start_x, campaign_scroll_region.x);
        try std.testing.expectEqual(standalone_scroll_region.width - stride, campaign_scroll_region.width);
    }
}

test "buildEditorPrimaryActions: Test + Validate icon buttons flush top-right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = @splat(black) },
    };

    var elements: UiElementList = .empty;
    try buildEditorPrimaryActions(&elements, arena.allocator(), theme);

    // Two icon buttons, each a button + overlaying image = 4 elements.
    try std.testing.expectEqual(@as(usize, 4), elements.items.len);

    // Test first (elements 0-1), Validate right of it (2-3): the top-bar
    // icon-button visual class (top_bar_slot_size square, bar height)
    // flush against the right screen edge.
    const test_button = elements.items[0].button;
    try std.testing.expectEqual(Action.test_editor_level, test_button.action);
    try std.testing.expectEqualStrings(small_button_background_sprite_id, test_button.sprite_id.?);
    try std.testing.expectEqualStrings("ui/icon_playtest", elements.items[1].image.sprite_id);
    try std.testing.expectEqual(@as(i32, types.reference_width - 2 * top_bar_slot_size - ui_gap), test_button.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), test_button.screen_position.y);
    try std.testing.expectEqual(top_bar_slot_size, test_button.width);
    try std.testing.expectEqual(top_bar_slot_size, test_button.height);
    try std.testing.expect(!elements.items[1].image.blocks_input); // button wins hit-test

    const validate_button = elements.items[2].button;
    try std.testing.expectEqual(Action.validate_editor_mission, validate_button.action);
    try std.testing.expectEqualStrings("ui/icon_validate", elements.items[3].image.sprite_id);
    try std.testing.expectEqual(@as(i32, types.reference_width - top_bar_slot_size), validate_button.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), validate_button.screen_position.y);
    try std.testing.expectEqual(top_bar_slot_size, validate_button.width);
    try std.testing.expectEqual(top_bar_slot_size, validate_button.height);
}

test "buildEditorLevelTabs: overflow clamps the window, pins the +, follows the active tab" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = @splat(black) },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    // Eight levels with very long names: each tab is far wider than a
    // third of the region, so the window shows exactly ONE tab and the
    // max scroll is the last index (7).
    var names: [8][]const u8 = undefined;
    for (&names, 0..) |*slot, index| {
        slot.* = try std.fmt.allocPrint(
            arena.allocator(),
            "An extremely long level name number {d} of eight",
            .{index + 1},
        );
    }
    var levels: [8]types.EditorLevel = undefined;
    for (&levels, 0..) |*slot, index| {
        slot.* = .{ .name = names[index] };
    }
    const editor: types.Editor = .{
        .levels = &levels,
        .active_level_index = 0,
    };

    // An over-scrolled offset clamps to the max (the last tab): the
    // window shows exactly tab 7. (The active tab is 7 too - the
    // active-follow below must NOT move the window past the clamp.)
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_level_tab_scroll = 999 };
        const last_active: types.Editor = .{ .levels = &levels, .active_level_index = 7 };
        try buildEditorLevelTabs(&elements, arena.allocator(), metrics, last_active, theme, &ui_state);
        try std.testing.expectEqual(@as(i32, 7), ui_state.editor_level_tab_scroll);
        // 1 tab x (panel + button + label + x) + the pinned "+" trio.
        try std.testing.expectEqual(@as(usize, 7), elements.items.len);
        try std.testing.expectEqualStrings(names[7], elements.items[2].text_label.text);
        // The visible tab stays clear of the pinned "+".
        const tab_panel = elements.items[0].nine_slice_panel;
        try std.testing.expect(tab_panel.screen_position.x + tab_panel.width <=
            types.reference_width - editor_primary_actions_width - ui_gap - editor_header_strip_height - ui_gap);
    }

    // The pinned "+": flush at the row's right edge, one ui_gap clear of
    // the primary-actions block.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorLevelTabs(&elements, arena.allocator(), metrics, editor, theme, &ui_state);
        const plus_panel = elements.items[4].nine_slice_panel;
        try std.testing.expectEqual(
            @as(i32, types.reference_width - editor_primary_actions_width - ui_gap - editor_header_strip_height),
            plus_panel.screen_position.x,
        );
        try std.testing.expectEqual(@as(i32, 0), plus_panel.screen_position.y);
    }

    // Active-tab follow: the active tab beyond the window scrolls the
    // window to it (the add-level flow's "land on the new tab").
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        const last_active: types.Editor = .{ .levels = &levels, .active_level_index = 7 };
        try buildEditorLevelTabs(&elements, arena.allocator(), metrics, last_active, theme, &ui_state);
        try std.testing.expectEqual(@as(i32, 7), ui_state.editor_level_tab_scroll);
        try std.testing.expectEqualStrings(names[7], elements.items[2].text_label.text);
    }
    {
        // The active tab BEHIND the window scrolls back to it.
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_level_tab_scroll = 7 };
        const early_active: types.Editor = .{ .levels = &levels, .active_level_index = 2 };
        try buildEditorLevelTabs(&elements, arena.allocator(), metrics, early_active, theme, &ui_state);
        try std.testing.expectEqual(@as(i32, 2), ui_state.editor_level_tab_scroll);
        try std.testing.expectEqualStrings(names[2], elements.items[2].text_label.text);
    }
    {
        // A MANUAL scroll away from the active tab STICKS: the follow fires
        // only on a CHANGE of the active tab (the regression - running it
        // every frame snapped the window back and made scrolling
        // impossible, with the reachable band depending on the active
        // tab's position).
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_level_tab_scroll = 5,
            .editor_level_tab_last_active = 0, // unchanged since the last build
        };
        const active_zero: types.Editor = .{ .levels = &levels, .active_level_index = 0 };
        try buildEditorLevelTabs(&elements, arena.allocator(), metrics, active_zero, theme, &ui_state);
        try std.testing.expectEqual(@as(i32, 5), ui_state.editor_level_tab_scroll);
        try std.testing.expectEqualStrings(names[5], elements.items[2].text_label.text);
    }
}

test "buildEditorBottomBar: fixed tools + palette groups + plus cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const world_one: types.Color = .{ .r = 10, .g = 10, .b = 10 };
    const enemy_two: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const player_one: types.Color = .{ .r = 30, .g = 30, .b = 30 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{ black, world_one, black, black, black, black } },
        .enemy_gradient = .{ .colors = .{ black, black, enemy_two, black, black, black } },
        .player_gradient = .{ .colors = .{ black, player_one, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    var entity_template: types.Entity = .{};
    entity_template.sprite = "skeleton";
    entity_template.team = 1;
    entity_template.color_index = 2;
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton Warrior", .template = entity_template },
    };
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "Ruin", .sprite = "ruin_1", .pixel_dims = .{ .x = 512, .y = 512 } },
    };
    const item_types = [_]types.ItemTypeDef{
        .{ .id = "Iron Sword", .item = .{ .weapon = .{} } },
    };
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
        .item_types = &item_types,
    };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 0, 0 };
    var collapsed: [3]bool = .{ false, false, false };
    try buildEditorBottomBar(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        editor,
        theme,
        &scroll_offsets,
        &collapsed,
        .select,
    );

    // 2 fixed tools × (bg + graphic) + 3 groups × 9 (header panel +
    // button + label + plus trio + type bg + graphic + delete button).
    try std.testing.expectEqual(@as(usize, 2 * 2 + 3 * 9), elements.items.len);

    // Every tool graphic sits on a button_background cell at the bottom of the
    // screen: 5 tool cells (2 fixed + 3 palette types) - the "+" cells are
    // square ui/panel cells in the header strip, out of the bar band.
    var background_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.sprite_id != null and
                std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                background_count += 1;
                try std.testing.expectEqual(bottom_bar_height, button.height);
                try std.testing.expectEqual(
                    types.reference_height - bottom_bar_height,
                    button.screen_position.y,
                );
            }
        },
        else => {},
    };
    // 2 fixed tools + one type cell per palette group's window.
    const tool_cell_count = 2 + entity_types.len + decoration_types.len + item_types.len;
    try std.testing.expectEqual(@as(usize, tool_cell_count), background_count);

    // Fixed tools: Select draws as an inset STROKED square (the
    // clickable-tile highlight's outline class - the retired
    // tile_highlight sheet is gone); Tile uses world/tile tinted with the
    // world gradient index 1.
    var found_select_outline = false;
    var found_tile = false;
    var found_enemy = false;
    var found_decoration = false;
    var found_item = false;
    for (elements.items) |element| switch (element) {
        .solid_rect => |rect| {
            if (!rect.filled) found_select_outline = true;
        },
        .image => |image| {
            if (std.mem.eql(u8, image.sprite_id, "world/tile")) {
                found_tile = std.meta.eql(image.color, world_one);
            } else if (std.mem.eql(u8, image.sprite_id, "entities/skeleton")) {
                found_enemy = std.meta.eql(image.color, enemy_two) and
                    image.width == 204 and image.height == 256;
            } else if (std.mem.eql(u8, image.sprite_id, "decorations/ruin_1")) {
                found_decoration = image.width == 256 and image.height == 256;
            } else if (std.mem.eql(u8, image.sprite_id, "items/sword")) {
                found_item = std.meta.eql(image.color, player_one) and
                    image.width == 256 and image.height == 256;
            }
        },
        else => {},
    };
    try std.testing.expect(found_select_outline);
    try std.testing.expect(found_tile);
    try std.testing.expect(found_enemy);
    try std.testing.expect(found_decoration);
    try std.testing.expect(found_item);

    // Three group headers + three "+" glyphs, all non-blocking overlays.
    // Headers sit ABOVE the bar (the strip the in-game indicators use),
    // left-aligned with their group's first cell; the "+" glyphs center on
    // their square panel cells beside the headers.
    var header_count: usize = 0;
    var plus_button_count: usize = 0;
    var delete_button_count: usize = 0;
    var enemies_header: ?types.ScreenPosition = null;
    var enemies_header_button: ?types.ScreenPosition = null;
    var enemies_header_width: i32 = 0;
    var enemies_plus_button: ?types.ScreenPosition = null;
    var decorations_header_button: ?types.ScreenPosition = null;
    var first_enemy_cell: ?types.ScreenPosition = null;
    const header_top: i32 = types.reference_height - bottom_bar_height - ui_gap - editor_header_strip_height;
    var enemy_cell_index: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            // The header + "+" buttons BOTH carry the group payload - tell
            // them apart by action.
            if (button.action == .toggle_editor_palette_group and button.payload.?.editor_group == 0) {
                enemies_header_button = button.screen_position;
                enemies_header_width = button.width;
            }
            if (button.action == .toggle_editor_palette_group and button.payload.?.editor_group == 1) {
                decorations_header_button = button.screen_position;
            }
            if (button.action == .add_editor_palette_type) {
                plus_button_count += 1;
                try std.testing.expect(button.payload.?.editor_group >= 0);
                try std.testing.expect(button.sprite_id == null); // spriteless over the panel
                if (button.payload.?.editor_group == 0) enemies_plus_button = button.screen_position;
            }
            if (button.action == .delete_editor_palette_type) {
                delete_button_count += 1;
                // The shared close-button visual, flush in the tool cell's
                // top-right corner (the cell's top = the bar band's top),
                // carrying the cell's tool.
                try std.testing.expectEqualStrings(close_button_sprite_id, button.sprite_id.?);
                try std.testing.expectEqual(close_button_size, button.width);
                try std.testing.expectEqual(close_button_size, button.height);
                try std.testing.expectEqual(
                    types.reference_height - bottom_bar_height,
                    button.screen_position.y,
                );
                try std.testing.expect(std.meta.activeTag(button.payload.?) == .editor_tool);
            }
            if (button.sprite_id != null and
                std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                // Cells emit in order: Select, Tile, enemy, ...
                if (enemy_cell_index == 2) first_enemy_cell = button.screen_position;
                enemy_cell_index += 1;
            }
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Entities")) {
                enemies_header = label.screen_position;
                try std.testing.expect(!label.blocks_input);
            } else if (std.mem.eql(u8, label.text, "+") or
                std.mem.eql(u8, label.text, "Decorations") or
                std.mem.eql(u8, label.text, "Items"))
            {
                header_count += 1;
                try std.testing.expect(!label.blocks_input);
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), header_count);
    try std.testing.expectEqual(@as(usize, 3), plus_button_count);
    try std.testing.expectEqual(@as(usize, 3), delete_button_count);
    try std.testing.expect(enemies_header != null);
    try std.testing.expect(enemies_header_button != null);
    try std.testing.expect(first_enemy_cell != null);
    // Label is centered in the 128-high header button.
    try std.testing.expectEqual(
        header_top + @divTrunc(editor_header_strip_height - editor_group_header_font_size, 2),
        enemies_header.?.y,
    );
    // The header BUTTON is left-aligned with the group's first cell.
    try std.testing.expectEqual(first_enemy_cell.?.x, enemies_header_button.?.x);
    // The "+" sits one ui_gap right of the header (not flush against it).
    try std.testing.expect(enemies_plus_button != null);
    try std.testing.expectEqual(
        enemies_header_button.?.x + enemies_header_width + ui_gap,
        enemies_plus_button.?.x,
    );
    // ...and one ui_gap LEFT of the next group's header too (the
    // footprint includes the header-+ extent, so the row's join gap
    // survives past the "+").
    try std.testing.expect(decorations_header_button != null);
    try std.testing.expectEqual(
        enemies_plus_button.?.x + editor_plus_size + ui_gap,
        decorations_header_button.?.x,
    );
}

test "buildEditorBottomBar: entity + decoration cells render the full scene composition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const world_one: types.Color = .{ .r = 10, .g = 10, .b = 10 };
    const world_three: types.Color = .{ .r = 11, .g = 11, .b = 11 };
    const enemy_one: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const enemy_two: types.Color = .{ .r = 21, .g = 21, .b = 21 };
    const enemy_four: types.Color = .{ .r = 22, .g = 22, .b = 22 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{ black, world_one, black, world_three, black, black } },
        .enemy_gradient = .{ .colors = .{ black, enemy_one, enemy_two, black, enemy_four, black } },
        .player_gradient = .{ .colors = .{ black, black, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    // A layered, dual-wielding enemy - the composed case.
    var skeleton: types.Entity = .{};
    skeleton.sprite = "skeleton";
    skeleton.team = 1;
    skeleton.color_index = 2;
    const skeleton_layers = [_]types.EntityLayer{.{ .sprite = "skeleton_armor", .color_index = 4 }};
    skeleton.layers = &skeleton_layers;
    skeleton.main_hand_weapon = .{ .weapon_type = .sword };
    skeleton.off_hand_weapon = .{ .weapon_type = .dagger };

    // A weapon-suppressed enemy - weapons stay hidden even when equipped.
    var wolf: types.Entity = .{};
    wolf.sprite = "wolf";
    wolf.team = 1;
    wolf.displays_weapons = false;
    wolf.main_hand_weapon = .{ .weapon_type = .axe };

    // A keep_original_colors enemy - base + layers UNTINTED, weapons
    // still themed (our art).
    var custom_fighter: types.Entity = .{};
    custom_fighter.sprite = "custom_fighter";
    custom_fighter.team = 1;
    custom_fighter.color_index = 2;
    custom_fighter.keep_original_colors = true;
    const fighter_layers = [_]types.EntityLayer{.{ .sprite = "custom_helmet", .color_index = 4 }};
    custom_fighter.layers = &fighter_layers;
    // A spear: distinct from the skeleton's sword/dagger and the wolf's
    // suppressed axe, so the themed weapon image below is unambiguously
    // the fighter's.
    custom_fighter.main_hand_weapon = .{ .weapon_type = .spear };

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton Warrior", .template = skeleton },
        .{ .id = "Wolf", .template = wolf },
        .{ .id = "Custom Fighter", .template = custom_fighter },
    };
    const ruin_layers = [_]types.DecorationLayer{.{
        .sprite = "ruin_1_moss",
        .color_index = 3,
        .pixel_dims = .{ .x = 512, .y = 512 },
    }};
    const moss_layers = [_]types.DecorationLayer{.{
        .sprite = "moss_vine",
        .color_index = 4,
        .pixel_dims = .{ .x = 512, .y = 512 },
    }};

    const decoration_types = [_]types.DecorationTypeDef{
        .{
            .id = "Ruin",
            .sprite = "ruin_1",
            .pixel_dims = .{ .x = 512, .y = 512 },
            .color_index = 1,
            .layers = &ruin_layers,
        },
        // keep_original_colors: base + layers UNTINTED (the authored
        // world-three index is overridden).
        .{
            .id = "Moss",
            .sprite = "moss_1",
            .pixel_dims = .{ .x = 512, .y = 512 },
            .color_index = 3,
            .keep_original_colors = true,
            .layers = &moss_layers,
        },
    };
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
    };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 0, 0 };
    var collapsed: [3]bool = .{ false, false, false };
    try buildEditorBottomBar(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        editor,
        theme,
        &scroll_offsets,
        &collapsed,
        .select,
    );

    // Collect the composed-cell images by sprite id.
    var base_image: ?Image = null;
    var layer_image: ?Image = null;
    var main_weapon_image: ?Image = null;
    var off_weapon_image: ?Image = null;
    var wolf_image: ?Image = null;
    var axe_seen = false;
    var decoration_base_image: ?Image = null;
    var decoration_layer_image: ?Image = null;
    for (elements.items) |element| switch (element) {
        .image => |image| {
            try std.testing.expect(!image.blocks_input);
            if (std.mem.eql(u8, image.sprite_id, "entities/skeleton")) {
                base_image = image;
            } else if (std.mem.eql(u8, image.sprite_id, "entities/skeleton_armor")) {
                layer_image = image;
            } else if (std.mem.eql(u8, image.sprite_id, "weapons/enemy_sword")) {
                main_weapon_image = image;
            } else if (std.mem.eql(u8, image.sprite_id, "weapons/enemy_dagger")) {
                off_weapon_image = image;
            } else if (std.mem.eql(u8, image.sprite_id, "entities/wolf")) {
                wolf_image = image;
            } else if (std.mem.eql(u8, image.sprite_id, "weapons/enemy_axe")) {
                axe_seen = true;
            } else if (std.mem.eql(u8, image.sprite_id, "decorations/ruin_1")) {
                decoration_base_image = image;
            } else if (std.mem.eql(u8, image.sprite_id, "decorations/ruin_1_moss")) {
                decoration_layer_image = image;
            }
        },
        else => {},
    };

    // Entity stack: base at the template's color_index, layer at its own,
    // weapons at gradient index 1 - the entityDrawable tint rules.
    try std.testing.expect(base_image != null);
    try std.testing.expect(layer_image != null);
    try std.testing.expect(main_weapon_image != null);
    try std.testing.expect(off_weapon_image != null);
    try std.testing.expect(std.meta.eql(base_image.?.color, enemy_two));
    try std.testing.expect(std.meta.eql(layer_image.?.color, enemy_four));
    try std.testing.expect(std.meta.eql(main_weapon_image.?.color, enemy_one));
    try std.testing.expect(std.meta.eql(off_weapon_image.?.color, enemy_one));

    // The whole stack shares one fitted rect (entity art shares the
    // 512x640 frame + pivot) - the off-hand mirrors instead of moving.
    try std.testing.expect(!main_weapon_image.?.flip_horizontal);
    try std.testing.expect(off_weapon_image.?.flip_horizontal);
    for ([_]?Image{ layer_image, main_weapon_image, off_weapon_image }) |maybe_image| {
        const image = maybe_image.?;
        try std.testing.expectEqual(base_image.?.screen_position.x, image.screen_position.x);
        try std.testing.expectEqual(base_image.?.screen_position.y, image.screen_position.y);
        try std.testing.expectEqual(base_image.?.width, image.width);
        try std.testing.expectEqual(base_image.?.height, image.height);
    }

    // displays_weapons false: the wolf's base shows, its axe does not.
    try std.testing.expect(wolf_image != null);
    try std.testing.expect(!axe_seen);

    // Decoration stack: base + layer at their own color indices into the
    // world gradient, sharing one fitted rect.
    try std.testing.expect(decoration_base_image != null);
    try std.testing.expect(decoration_layer_image != null);
    try std.testing.expect(std.meta.eql(decoration_base_image.?.color, world_one));
    try std.testing.expect(std.meta.eql(decoration_layer_image.?.color, world_three));
    try std.testing.expectEqual(
        decoration_base_image.?.screen_position.x,
        decoration_layer_image.?.screen_position.x,
    );
    try std.testing.expectEqual(
        decoration_base_image.?.screen_position.y,
        decoration_layer_image.?.screen_position.y,
    );
    try std.testing.expectEqual(decoration_base_image.?.width, decoration_layer_image.?.width);
    try std.testing.expectEqual(decoration_base_image.?.height, decoration_layer_image.?.height);

    // keep_original_colors cells: base + layers UNTINTED (the entity's
    // weapons stay gradient index 1 - our art, always themed).
    var fighter_base_untinted = false;
    var fighter_layer_untinted = false;
    var fighter_weapons_themed = false;
    var moss_untinted = false;
    var moss_layer_untinted = false;
    for (elements.items) |element| switch (element) {
        .image => |image| {
            if (std.mem.eql(u8, image.sprite_id, "entities/custom_fighter")) {
                fighter_base_untinted = std.meta.eql(image.color, default_tint);
            } else if (std.mem.eql(u8, image.sprite_id, "entities/custom_helmet")) {
                fighter_layer_untinted = std.meta.eql(image.color, default_tint);
            } else if (std.mem.eql(u8, image.sprite_id, "weapons/enemy_spear")) {
                // The fighter's weapon stays gradient index 1 - the flag
                // untints the asset's art, not ours (the wolf's spear is
                // suppressed, so this image is the fighter's).
                fighter_weapons_themed = std.meta.eql(image.color, enemy_one);
            } else if (std.mem.eql(u8, image.sprite_id, "decorations/moss_1")) {
                moss_untinted = std.meta.eql(image.color, default_tint);
            } else if (std.mem.eql(u8, image.sprite_id, "decorations/moss_vine")) {
                moss_layer_untinted = std.meta.eql(image.color, default_tint);
            }
        },
        else => {},
    };
    try std.testing.expect(fighter_base_untinted);
    try std.testing.expect(fighter_layer_untinted);
    try std.testing.expect(fighter_weapons_themed);
    try std.testing.expect(moss_untinted);
    try std.testing.expect(moss_layer_untinted);
}

test "buildEditorBottomBar: collapsed groups sit flush bottom; expanded hover above" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = @splat(black) },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton" }};
    const editor: types.Editor = .{ .entity_types = &entity_types };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 0, 0 };
    // Entities (group 0) expanded; Decorations + Items collapsed.
    var collapsed: [3]bool = .{ false, true, true };
    try buildEditorBottomBar(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        editor,
        theme,
        &scroll_offsets,
        &collapsed,
        .select,
    );

    const flush_bottom_y = types.reference_height - editor_header_strip_height;
    const hovering_y = types.reference_height - bottom_bar_height - ui_gap - editor_header_strip_height;

    // Expanded group 0: header + "+" hover in the strip above the bar,
    // and its type cell is in the bar band.
    // Collapsed groups 1 + 2: header + "+" sit flush against the bottom
    // of the screen, and emit no type cells.
    var group_header_y: [3]?i32 = .{ null, null, null };
    var plus_panels: usize = 0;
    var bar_band_tool_cells: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.payload) |payload| {
                switch (payload) {
                    .editor_group => |group_index| group_header_y[group_index] = button.screen_position.y,
                    else => {},
                }
            }
            if (button.sprite_id != null and
                std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                bar_band_tool_cells += 1;
            }
        },
        .nine_slice_panel => |panel| {
            // The three "+" cells: square ui/panel cells (their y is asserted
            // via the paired "+" glyphs below).
            if (panel.width == editor_plus_size and panel.height == editor_plus_size) {
                plus_panels += 1;
            }
        },
        else => {},
    };

    // Tool cells: 2 fixed + the 1 expanded enemy type (collapsed groups
    // contribute none).
    try std.testing.expectEqual(@as(usize, 3), bar_band_tool_cells);

    try std.testing.expectEqual(hovering_y, group_header_y[0].?);
    try std.testing.expectEqual(flush_bottom_y, group_header_y[1].?);
    try std.testing.expectEqual(flush_bottom_y, group_header_y[2].?);

    // The "+" panels pair with their group headers by adjacency: group 0's
    // plus hovers, groups 1 + 2's sit flush bottom. Assert via the glyph
    // labels' y instead of x bookkeeping (each "+" glyph centers on its
    // panel).
    var plus_glyph_ys: [3]i32 = undefined;
    var plus_ys_found: usize = 0;
    var decoration_header_x: ?i32 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            const group_index = switch (button.payload orelse continue) {
                .editor_group => |g| g,
                else => continue,
            };
            if (group_index == 1) decoration_header_x = button.screen_position.x;
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "+")) {
                plus_glyph_ys[plus_ys_found] = label.screen_position.y;
                plus_ys_found += 1;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), plus_panels);
    try std.testing.expectEqual(@as(usize, 3), plus_ys_found);
    // Emission order is group order, so glyph 0 hovers, 1 + 2 flush bottom.
    try std.testing.expectEqual(
        hovering_y + @divTrunc(editor_header_strip_height - editor_group_header_font_size, 2),
        plus_glyph_ys[0],
    );
    try std.testing.expectEqual(
        flush_bottom_y + @divTrunc(editor_header_strip_height - editor_group_header_font_size, 2),
        plus_glyph_ys[1],
    );
    try std.testing.expectEqual(
        flush_bottom_y + @divTrunc(editor_header_strip_height - editor_group_header_font_size, 2),
        plus_glyph_ys[2],
    );
    try std.testing.expect(decoration_header_x != null);

    // An EXPANDED group with NO tools rises to the strip too: the header
    // moves on expand consistently - it doesn't stay pinned to the bottom
    // edge just because there are no cells to label. (The editor above
    // has no decoration types, so group 1 expanded = the empty case.)
    {
        var empty_expanded_elements: UiElementList = .empty;
        var empty_expanded_scroll_offsets: [3]i32 = .{ 0, 0, 0 };
        // Entities collapsed; Decorations (EMPTY) expanded; Items collapsed.
        var empty_expanded_collapsed: [3]bool = .{ true, false, true };
        try buildEditorBottomBar(
            &empty_expanded_elements,
            arena.allocator(),
            metrics,
            screenRect(),
            editor,
            theme,
            &empty_expanded_scroll_offsets,
            &empty_expanded_collapsed,
            .select,
        );
        var empty_group_header_y: ?i32 = null;
        var empty_group_plus_y: ?i32 = null;
        for (empty_expanded_elements.items) |element| switch (element) {
            .button => |button| {
                const group_index = switch (button.payload orelse continue) {
                    .editor_group => |g| g,
                    else => continue,
                };
                if (group_index != 1) continue;
                if (button.action == .toggle_editor_palette_group) {
                    empty_group_header_y = button.screen_position.y;
                } else if (button.action == .add_editor_palette_type) {
                    empty_group_plus_y = button.screen_position.y;
                }
            },
            else => {},
        };
        try std.testing.expectEqual(hovering_y, empty_group_header_y.?);
        try std.testing.expectEqual(hovering_y, empty_group_plus_y.?);
    }
}

test "buildEditorBottomBar: group window clamps to max 8 tools + scrolls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = @splat(black) },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    // 12 decorations → window of 8, max offset 4. All others sized 1.
    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton" }};
    var decoration_types: [12]types.DecorationTypeDef = undefined;
    for (&decoration_types, 0..) |*type_definition, index| {
        type_definition.* = .{
            .id = try std.fmt.allocPrint(arena.allocator(), "Ruin {d}", .{index}),
            .sprite = "ruin_1",
            .pixel_dims = .{ .x = 512, .y = 512 },
        };
    }
    const item_types = [_]types.ItemTypeDef{.{ .id = "Iron Sword" }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
        .item_types = &item_types,
    };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 99, 0 }; // over-scrolled → clamps to 4
    var collapsed: [3]bool = .{ false, false, false };
    try buildEditorBottomBar(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        editor,
        theme,
        &scroll_offsets,
        &collapsed,
        .select,
    );

    // The over-scrolled offset clamps to size − max (derived from the
    // same constant the builder clamps with); negative would clamp to 0.
    const expected_window = @min(decoration_types.len, editor_palette_max_tools);
    const expected_clamp: i32 = @intCast(decoration_types.len - expected_window);
    try std.testing.expectEqual(expected_clamp, scroll_offsets[1]);

    // Count decoration tool cells: exactly 8 (the window). Tooltips live
    // on the button_background image, which is emitted immediately BEFORE
    // its graphic - pair them by position. The window starting at 4 shows
    // types 4..11 - the FIRST type ("Ruin 0") is NOT among them, the LAST
    // ("Ruin 11") is.
    var decoration_cells: usize = 0;
    var found_first = false;
    var found_last = false;
    var previous_tooltip: ?Tooltip = null;
    for (elements.items) |element| switch (element) {
        .button => |button| previous_tooltip = button.tooltip,
        .image => |image| {
            if (std.mem.eql(u8, image.sprite_id, "decorations/ruin_1")) {
                decoration_cells += 1;
                const tooltip = previous_tooltip.?; // button precedes its graphic
                const header = tooltip.header.?[0].text;
                if (std.mem.eql(u8, header, "Ruin 0")) found_first = true;
                if (std.mem.eql(u8, header, "Ruin 11")) found_last = true;
            }
        },
        else => {
            previous_tooltip = null;
        },
    };
    try std.testing.expectEqual(@as(usize, expected_window), decoration_cells);
    try std.testing.expect(!found_first);
    try std.testing.expect(found_last);

    // Group detection: pointer over a decoration cell maps to group 1
    // (Decorations); over a fixed tool or above the bar maps to null.
    const tool_backgrounds: usize = blk: {
        var count: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.sprite_id != null and std.mem.eql(
                u8,
                button.sprite_id.?,
                button_background_sprite_id,
            ) and button.screen_position.y >= types.reference_height - bottom_bar_height) {
                count += 1;
            },
            else => {},
        };
        break :blk count;
    };
    // 2 fixed + the enemy window + the decoration window + the item
    // (pluses are in the header strip, out of the bar band).
    try std.testing.expectEqual(
        @as(usize, 2 + entity_types.len + expected_window + item_types.len),
        tool_backgrounds,
    );

    // The first decoration window cell (found by the button that
    // immediately precedes its graphic - the button/image pairing, not
    // an emission index): group detection maps it to group 1
    // (Decorations).
    var decoration_cell_center: ?types.ScreenPosition = null;
    var previous_button_center: ?types.ScreenPosition = null;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            previous_button_center = .{
                .x = button.screen_position.x + @divTrunc(button.width, 2),
                .y = button.screen_position.y + @divTrunc(button.height, 2),
            };
        },
        .image => |image| {
            if (decoration_cell_center == null and std.mem.eql(u8, image.sprite_id, "decorations/ruin_1")) {
                decoration_cell_center = previous_button_center;
            }
        },
        else => {},
    };
    try std.testing.expect(decoration_cell_center != null);
    try std.testing.expectEqual(
        @as(?usize, 1),
        editorPaletteGroupAt(editor, collapsed, elements.items, decoration_cell_center.?),
    );
    // Above the bar: null regardless of x.
    try std.testing.expectEqual(
        @as(?usize, null),
        editorPaletteGroupAt(editor, collapsed, elements.items, .{ .x = decoration_cell_center.?.x, .y = 0 }),
    );
    // Fixed tool (first cell): null - not a palette group.
    var first_cell_center: ?types.ScreenPosition = null;
    {
        var index: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.sprite_id != null and
                    std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                    button.screen_position.y >= types.reference_height - bottom_bar_height)
                {
                    if (index == 0) {
                        first_cell_center = .{
                            .x = button.screen_position.x + @divTrunc(button.width, 2),
                            .y = button.screen_position.y + @divTrunc(button.height, 2),
                        };
                    }
                    index += 1;
                }
            },
            else => {},
        };
    }
    try std.testing.expect(first_cell_center != null);
    try std.testing.expectEqual(
        @as(?usize, null),
        editorPaletteGroupAt(editor, collapsed, elements.items, first_cell_center.?),
    );
}

test "buildEditorBottomBar: a team-0 entity tool cell tints with the player gradient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const player_two: types.Color = .{ .r = 22, .g = 22, .b = 22 };
    var player_gradient: [types.gradient_color_count]types.Color = @splat(black);
    player_gradient[2] = player_two;
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = player_gradient },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    // A player-team HELPER: team 0 with its own color_index (2) - the cell
    // graphic tints player-gradient[2], not the enemy gradient (DESIGN →
    // Entity & UI Coloring).
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Helper",
        .template = .{ .name = "Helper", .sprite = "skeleton", .team = 0, .color_index = 2 },
    }};
    const editor: types.Editor = .{ .entity_types = &entity_types };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 0, 0 };
    var collapsed: [3]bool = .{ false, false, false };
    try buildEditorBottomBar(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        editor,
        theme,
        &scroll_offsets,
        &collapsed,
        .select,
    );

    var found_helper_cell = false;
    for (elements.items) |element| switch (element) {
        .image => |image| if (std.mem.eql(u8, image.sprite_id, "entities/skeleton")) {
            try std.testing.expect(std.meta.eql(player_two, image.color));
            found_helper_cell = true;
        },
        else => {},
    };
    try std.testing.expect(found_helper_cell);
}
