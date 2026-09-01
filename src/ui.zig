//! UI framework facade + the panel/overlay builders that have not moved
//! out yet. The framework CORE lives in `ui/`: element.zig (the flat
//! `UiElement` union + variants, Rect algebra, layout constants,
//! `FontMetrics`, hit-testing), state.zig (`UiState` + drag/click/marquee
//! lifecycles), text_input.zig (the text-field widget). The re-exports
//! below keep `ui.X` working for every consumer, and the builders here use
//! the same names. Builders remaining in this file: tooltips, error popup,
//! bottom bar, the editor chrome/inspector/pickers/palette, the in-game
//! middle panels, and the menus/screens. See DESIGN → UI Framework.

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const lookups = @import("generated_lookups.zig");
const utility_skills = @import("utility_skills.zig");
const loaders = @import("loaders.zig");
const sprite_metadata = @import("generated_sprite_metadata");
const Skill = @import("skills/skill.zig").Skill;
const Effect = @import("effects/effect.zig").Effect;

const Action = types.Action;
const ScreenPosition = types.ScreenPosition;
const Rectangle = types.Rectangle;
const Color = types.Color;
const Entity = types.Entity;
const SkillId = types.SkillId;
const GearSlot = types.GearSlot;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const ui_element = @import("ui/element.zig");
const ui_state_mod = @import("ui/state.zig");
const ui_text_input = @import("ui/text_input.zig");

pub const SlotRef = ui_element.SlotRef;
pub const Span = ui_element.Span;
pub const TooltipRow = ui_element.TooltipRow;
pub const Tooltip = ui_element.Tooltip;
pub const text = ui_element.text;
pub const colored = ui_element.colored;
pub const bold = ui_element.bold;
pub const italic = ui_element.italic;
pub const glyph_spacing_font_divisor = ui_element.glyph_spacing_font_divisor;
pub const FontMetrics = ui_element.FontMetrics;
pub const lineHeight = ui_element.lineHeight;
pub const top_bar_height = ui_element.top_bar_height;
pub const bottom_bar_height = ui_element.bottom_bar_height;
pub const slot_size = ui_element.slot_size;
pub const swap_button_size = ui_element.swap_button_size;
pub const menu_button_width = ui_element.menu_button_width;
pub const menu_button_font_size = ui_element.menu_button_font_size;
pub const main_menu_title_font_size = ui_element.main_menu_title_font_size;
pub const main_menu_title_gap = ui_element.main_menu_title_gap;
pub const panel_button_height = ui_element.panel_button_height;
pub const small_icon_size = ui_element.small_icon_size;
pub const health_globe_ball_size = ui_element.health_globe_ball_size;
pub const health_globe_border_width = ui_element.health_globe_border_width;
pub const health_globe_border_height = ui_element.health_globe_border_height;
pub const ui_gap = ui_element.ui_gap;
pub const slot_padding = ui_element.slot_padding;
pub const drag_threshold_pixels = ui_element.drag_threshold_pixels;
pub const double_click_threshold_us = ui_element.double_click_threshold_us;
pub const inventory_slot_size = ui_element.inventory_slot_size;
pub const inventory_panel_width = ui_element.inventory_panel_width;
pub const middle_panel_height = ui_element.middle_panel_height;
pub const middle_panel_header_height = ui_element.middle_panel_header_height;
pub const close_button_size = ui_element.close_button_size;
pub const middle_panel_header_font_size = ui_element.middle_panel_header_font_size;
pub const close_button_sprite_id = ui_element.close_button_sprite_id;
pub const skills_panel_width = ui_element.skills_panel_width;
pub const skills_panel_columns = ui_element.skills_panel_columns;
pub const skills_scrollbar_width = ui_element.skills_scrollbar_width;
pub const entity_inspect_panel_width = ui_element.entity_inspect_panel_width;
pub const default_tint = ui_element.default_tint;
pub const screenRect = ui_element.screenRect;
pub const rowWidth = ui_element.rowWidth;
pub const Row = ui_element.Row;
pub const Grid = ui_element.Grid;
pub const NineSlicePanel = ui_element.NineSlicePanel;
pub const NineSlicePiece = ui_element.NineSlicePiece;
pub const nineSlicePieces = ui_element.nineSlicePieces;
pub const Slot = ui_element.Slot;
pub const Button = ui_element.Button;
pub const Slider = ui_element.Slider;
pub const TextLabel = ui_element.TextLabel;
pub const FillSprite = ui_element.FillSprite;
pub const Image = ui_element.Image;
pub const UiElement = ui_element.UiElement;
pub const TextFieldUi = ui_element.TextFieldUi;
pub const SolidRect = ui_element.SolidRect;
pub const boundsOf = ui_element.boundsOf;
pub const tooltipOf = ui_element.tooltipOf;
pub const blocksInputOf = ui_element.blocksInputOf;
pub const tooltipAt = ui_element.tooltipAt;
pub const buttonAt = ui_element.buttonAt;
pub const textFieldAt = ui_element.textFieldAt;
pub const buttonIndexAt = ui_element.buttonIndexAt;
pub const sliderAt = ui_element.sliderAt;
pub const findSlider = ui_element.findSlider;
pub const blockingElementAt = ui_element.blockingElementAt;
pub const slotAt = ui_element.slotAt;
pub const slotRefAt = ui_element.slotRefAt;
pub const refAt = ui_element.refAt;
pub const UiElementList = ui_element.UiElementList;
pub const MiddlePanelId = ui_state_mod.MiddlePanelId;
pub const FullScreenOverlayId = ui_state_mod.FullScreenOverlayId;
pub const max_middle_panels = ui_state_mod.max_middle_panels;
pub const max_full_screen_overlays = ui_state_mod.max_full_screen_overlays;
pub const EditorPickerTarget = ui_state_mod.EditorPickerTarget;
pub const editor_footprint_grid_cell_limit = ui_state_mod.editor_footprint_grid_cell_limit;
pub const editor_inspector_section_count = ui_state_mod.editor_inspector_section_count;
pub const UiState = ui_state_mod.UiState;
pub const DragState = ui_state_mod.DragState;
pub const ClickButton = ui_state_mod.ClickButton;
pub const PendingSlotPress = ui_state_mod.PendingSlotPress;
pub const PendingRightClick = ui_state_mod.PendingRightClick;
pub const LastItemClick = ui_state_mod.LastItemClick;
pub const SalvageRegion = ui_state_mod.SalvageRegion;
pub const EditorMarquee = ui_state_mod.EditorMarquee;
pub const EditorMoveDrag = ui_state_mod.EditorMoveDrag;
pub const TextEditState = ui_text_input.TextEditState;
pub const beginTextEdit = ui_text_input.beginTextEdit;
pub const routeTextInput = ui_text_input.routeTextInput;
pub const placeCaretFromClick = ui_text_input.placeCaretFromClick;
pub const wrapRow = ui_element.wrapRow;
const ui_tooltip = @import("ui/tooltip.zig");
const ui_emit = @import("ui/emit.zig");

pub const Side = ui_tooltip.Side;
pub const placeTooltip = ui_tooltip.placeTooltip;
pub const tooltip_max_width = ui_tooltip.tooltip_max_width;
pub const tooltip_padding = ui_tooltip.tooltip_padding;
pub const tooltip_row_gap = ui_tooltip.tooltip_row_gap;
pub const tooltip_header_gap = ui_tooltip.tooltip_header_gap;
pub const tooltip_header_font_size = ui_tooltip.tooltip_header_font_size;
pub const tooltip_body_font_size = ui_tooltip.tooltip_body_font_size;
pub const tooltip_panel_sprite = ui_tooltip.tooltip_panel_sprite;
pub const buildTooltip = ui_tooltip.buildTooltip;
pub const buildItemTooltip = ui_tooltip.buildItemTooltip;
pub const buildSkillTooltip = ui_tooltip.buildSkillTooltip;
pub const EquippedGear = ui_tooltip.EquippedGear;
pub const equippedGearFromEntity = ui_tooltip.equippedGearFromEntity;
pub const positive_color = ui_tooltip.positive_color;
pub const negative_color = ui_tooltip.negative_color;
pub const button_background_sprite_id = ui_emit.button_background_sprite_id;
pub const actionSkillSlot = ui_emit.actionSkillSlot;
pub const emitCenteredNumber = ui_emit.emitCenteredNumber;
pub const emitCornerNumber = ui_emit.emitCornerNumber;
pub const emitPanelHeader = ui_emit.emitPanelHeader;
pub const emitIconButton = ui_emit.emitIconButton;
pub const emitPanelButton = ui_emit.emitPanelButton;
pub const emitSkillButton = ui_emit.emitSkillButton;
pub const skillSlotAction = ui_emit.skillSlotAction;
pub const skillIconSpriteId = ui_emit.skillIconSpriteId;
pub const spanRow = ui_tooltip.spanRow;
pub const itemIconSpriteId = ui_emit.itemIconSpriteId;
pub const material_count_font_size = ui_emit.material_count_font_size;
pub const cooldown_font_size = ui_emit.cooldown_font_size;
pub const overlay_font_size = ui_emit.overlay_font_size;
const ui_editor_chrome = @import("ui/editor_chrome.zig");

pub const editor_entity_frame_width = ui_editor_chrome.editor_entity_frame_width;
pub const editor_entity_frame_height = ui_editor_chrome.editor_entity_frame_height;
pub const tile_highlight_frame_size = ui_editor_chrome.tile_highlight_frame_size;
pub const editor_group_header_font_size = ui_editor_chrome.editor_group_header_font_size;
pub const editor_header_strip_height = ui_editor_chrome.editor_header_strip_height;
pub const editor_plus_size = ui_editor_chrome.editor_plus_size;
pub const editor_palette_max_tools = ui_editor_chrome.editor_palette_max_tools;
pub const editorPaletteGroupSize = ui_editor_chrome.editorPaletteGroupSize;
pub const editorPaletteGroupAt = ui_editor_chrome.editorPaletteGroupAt;
pub const scaleToFit = ui_editor_chrome.scaleToFit;
pub const editor_primary_actions_width = ui_editor_chrome.editor_primary_actions_width;
pub const editorLevelTabScrollRegion = ui_editor_chrome.editorLevelTabScrollRegion;
pub const buildEditorLevelTabs = ui_editor_chrome.buildEditorLevelTabs;
pub const buildEditorPrimaryActions = ui_editor_chrome.buildEditorPrimaryActions;
pub const buildEditorBottomBar = ui_editor_chrome.buildEditorBottomBar;
const ui_editor_inspector = @import("ui/editor_inspector.zig");

pub const editor_inspector_width = ui_editor_inspector.editor_inspector_width;
pub const editor_inventory_slots_per_row = ui_editor_inspector.editor_inventory_slots_per_row;
pub const editor_inventory_row_count = ui_editor_inspector.editor_inventory_row_count;
pub const editor_inspector_row_height = ui_editor_inspector.editor_inspector_row_height;
pub const editor_inspector_scrollbar_width = ui_editor_inspector.editor_inspector_scrollbar_width;
pub const editor_metadata_sidebar_width = ui_editor_inspector.editor_metadata_sidebar_width;
pub const editorInspectorPanelRect = ui_editor_inspector.editorInspectorPanelRect;
pub const editorPickerOverlayRect = ui_editor_inspector.editorPickerOverlayRect;
pub const editorMetadataSidebarPanelRect = ui_editor_inspector.editorMetadataSidebarPanelRect;
pub const buildEditorInspectorPanel = ui_editor_inspector.buildEditorInspectorPanel;
pub const buildEditorMetadataSidebar = ui_editor_inspector.buildEditorMetadataSidebar;
pub const EditorInspectorTarget = ui_editor_inspector.EditorInspectorTarget;
pub const editorInspectorTarget = ui_editor_inspector.editorInspectorTarget;
pub const allInspectorSectionsExpanded = ui_editor_inspector.allInspectorSectionsExpanded;
pub const textEditPressProceeds = ui_editor_inspector.textEditPressProceeds;
pub const InspectorEntityContext = ui_editor_inspector.InspectorEntityContext;
pub const emitInspectorLayerButton = ui_editor_inspector.emitInspectorLayerButton;
pub const InspectorDecorationContext = ui_editor_inspector.InspectorDecorationContext;
pub const InspectorItemContext = ui_editor_inspector.InspectorItemContext;
const GameState = state.GameState;

const weapon_type_count = @typeInfo(types.WeaponType).@"enum".fields.len;

// ============================================================

/// The OFFICIAL enemy sprites (shipped `assets/entities/*.png`) as bare
/// stems — the sprite picker's Official tab. The player body is EXCLUDED
/// (the player sprite isn't an enemy base-sprite option). Comptime from
/// the sprite-metadata table; sorted for a stable picker order.
const official_entity_sprite_stems: []const []const u8 = build: {
    var stems: []const []const u8 = &.{};
    for (sprite_metadata.map.kvs.keys[0..sprite_metadata.map.kvs.len]) |key| {
        if (!std.mem.startsWith(u8, key, "entities/")) continue;
        if (std.mem.eql(u8, key, "entities/player")) continue;
        const stem = key["entities/".len..];
        // Insert in sorted position (comptime slices have const elements —
        // no in-place sort).
        var insert_index: usize = 0;
        while (insert_index < stems.len and std.mem.lessThan(u8, stems[insert_index], stem)) : (insert_index += 1) {}
        stems = stems[0..insert_index] ++ [_][]const u8{stem} ++ stems[insert_index..];
    }
    break :build stems;
};

/// One shipped decoration sprite (stem + pixel dims) for the picker's
/// layer-mode Official tab.
const OfficialDecorationSprite = struct {
    stem: []const u8,
    width: i32,
    height: i32,
};

/// The OFFICIAL decoration sprites (shipped `assets/decorations/*.png`) as
/// stems + pixel dims — the sprite picker's LAYER-mode Official tab (the
/// base-sprite mode lists the registry prefabs instead). Comptime from
/// the sprite-metadata table; a malformed dims string is a build bug.
const official_decoration_sprites: []const OfficialDecorationSprite = build: {
    @setEvalBranchQuota(20000);
    var list: []const OfficialDecorationSprite = &.{};
    for (sprite_metadata.map.kvs.keys[0..sprite_metadata.map.kvs.len]) |key| {
        if (!std.mem.startsWith(u8, key, "decorations/")) continue;
        const stem = key["decorations/".len..];
        const dims = sprite_metadata.map.get(key).?;
        const space = std.mem.indexOfScalar(u8, dims, ' ').?;
        const width = std.fmt.parseInt(i32, dims[0..space], 10) catch
            @compileError("malformed sprite dims string");
        const height = std.fmt.parseInt(i32, dims[space + 1 ..], 10) catch
            @compileError("malformed sprite dims string");
        var insert_index: usize = 0;
        while (insert_index < list.len and std.mem.lessThan(u8, list[insert_index].stem, stem)) : (insert_index += 1) {}
        list = list[0..insert_index] ++
            [_]OfficialDecorationSprite{.{ .stem = stem, .width = width, .height = height }} ++
            list[insert_index..];
    }
    break :build list;
};

// ============================================================

// ============================================================
// Tooltip placement (side-based)
// ============================================================

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
/// One body text line's height — also the scroll-step unit (arrow keys scroll
/// 3 lines at a time; see handleAnytimeInput). Kept in sync with
/// `lineHeight(error_body_font_size)`.
pub const error_scroll_line_height: i32 = 56;
/// Max body region height before scrolling kicks in. Leaves room for the
/// header + Dismiss button + padding within the 2160px reference height.
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
/// scrolls: only lines within the visible window are emitted, and a
/// scrollbar is drawn. `session.error_scroll_offset` is clamped to
/// `[0, max_scroll]` here (the view is the only place that knows
/// `max_scroll`, which depends on the wrapped line count). Pure over the
/// message + frame arena, aside from that scroll-offset clamp.
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
    const body_content_height: i32 = @intCast(body_lines.len * @as(usize, @intCast(body_line_height)));
    const visible_body_height = @min(body_content_height, error_popup_max_body_height);
    const max_scroll = @max(@as(i32, 0), body_content_height - visible_body_height);
    // Clamp the scroll offset (authoritative — the input handler can't know
    // max_scroll without wrapping the text itself).
    if (session.error_scroll_offset < 0) session.error_scroll_offset = 0;
    if (session.error_scroll_offset > max_scroll) session.error_scroll_offset = max_scroll;
    const scroll_offset = session.error_scroll_offset;
    const scrolls = body_content_height > visible_body_height;

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

    // Body: emit only the lines within the scroll window. Lines above
    // scroll_offset are above the visible region; lines below
    // (scroll_offset + visible_body_height) are below it. The renderer
    // would clip them anyway, but skipping them keeps the element list small
    // and the hit-test set clean.
    const body_top = y;
    const first_visible_line: usize = @intCast(@divTrunc(scroll_offset, body_line_height));
    const visible_line_count: usize = @intCast(@divTrunc(visible_body_height, body_line_height));
    const last_visible_line = @min(body_lines.len, first_visible_line + visible_line_count);
    // Skip the height of the lines above the scroll window.
    y += @intCast(first_visible_line * @as(usize, @intCast(body_line_height)));
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
    // total ratio and positioned by the scroll offset.
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
        const thumb_y = body_top + @divTrunc(scroll_offset * (visible_body_height - thumb_height), max_scroll);
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

// ============================================================
// Panel content builders — called by the view function
// ============================================================

/// The player entity is index 0 in a level, or the dedicated hub player.
pub fn playerEntity(game_state: *const GameState) ?Entity {
    if (game_state.level) |level| {
        if (level.entities.len > 0) return level.entities[0];
        return null;
    }
    if (game_state.hub) |hub| return hub.player;
    return null;
}

/// The bottom bar: one horizontally-centered row anchored to the bottom
/// of `screen`, laid out left-to-right as
///   inventory, gear, skills, health, weapon-skills, swap, utility-skills, skip
/// with `ui_gap` between top-level items. The two skill sub-bars pack
/// their buttons flush (no gap). Skip appears only in levels. The bar has
/// no background of its own — it is purely a layout region.
pub fn buildBottomBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    game_state: *const GameState,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    /// The slot currently being dragged from, if any. Suppresses the source
    /// skill's render so it reads as "in flight". Passed to `emitSkillButton`.
    drag_source: ?SlotRef,
) !void {
    const player = playerEntity(game_state) orelse return;
    const in_level = game_state.screen == .level;
    // The skill awaiting target confirmation (player_prepare_skill set it;
    // confirm/cancel/clear_prepared_skill clears it). Null in a hub (no
    // level) or when no skill is prepared. Used to highlight its slot.
    const prepared_skill: ?SkillId = if (in_level) blk: {
        if (game_state.level) |level| break :blk level.prepared_skill;
        break :blk null;
    } else null;

    // Player-gradient colors for the bottom bar elements.
    const p = active_theme.player_gradient.colors;
    const c_btn = p[@min(@as(u32, 4), types.gradient_color_count - 1)]; // inventory/gear/skills: 4
    const c_globe_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)]; // health bg: 5
    const c_globe_fill = p[@min(@as(u32, 1), types.gradient_color_count - 1)]; // health fill: 1
    const c_border = p[@min(@as(u32, 3), types.gradient_color_count - 1)]; // border/skill bg/skip bg/turn/swap/momentum: 3
    const c_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)]; // skill/skip icon: 1
    const c_skip_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)]; // skip bg: 5
    _ = player_color_index; // UI uses fixed indices, not the player's chosen index

    const weapon_skills_width = 3 * slot_size;
    const utility_skills_width = 5 * slot_size;

    // Total content width, to size and center the row.
    var top_level_count: i32 = 7; // inventory,gear,skills,health,wpn,swap,util
    // The health globe cell is wider than slot_size to fit its border at
    // native size (297 vs 256) — the border is authored wider than a slot, so
    // the cell matches it rather than letting the border overhang into the
    // gaps (which crowded the neighbors — see health_globe_border_width).
    var content_width = slot_size * 3 // inventory, gear, skills
        + health_globe_border_width // health (wider than a slot)
        + weapon_skills_width + swap_button_size + utility_skills_width;
    if (in_level) {
        top_level_count += 1;
        content_width += slot_size;
    }
    content_width += ui_gap * (top_level_count - 1);

    const bar = screen.placeBottomCenter(content_width, bottom_bar_height, 0);
    var row = Row.init(bar.position(), bottom_bar_height, ui_gap);

    // Panel toggle buttons.
    const toggles = [_]struct { sprite: []const u8, action: Action, label: []const u8 }{
        .{ .sprite = "ui/icon_inventory", .action = .toggle_inventory, .label = "Inventory" },
        .{ .sprite = "ui/icon_gear", .action = .toggle_gear, .label = "Gear" },
        .{ .sprite = "ui/icon_skills", .action = .toggle_skills, .label = "Skills" },
    };
    for (toggles) |toggle| {
        try elements.append(allocator, .{ .button = .{
            .sprite_id = toggle.sprite,
            .screen_position = row.next(slot_size).position(),
            .action = toggle.action,
            .color = c_btn,
            .tooltip = .{ .header = try spanRow(allocator, text(toggle.label)) },
        } });
    }

    // Health globe (vertical fill).
    const health_cell = row.next(health_globe_border_width);
    // One flat white ball serves as both background and fill; tint reads
    // them as depleted vs current health. Rendered at the ball's native
    // (downscaled) size, centered in the cell so it sits inside the border.
    const ball = health_cell.placeCenter(health_globe_ball_size, health_globe_ball_size);
    try elements.append(allocator, .{ .fill_sprite = .{
        .background_sprite_id = "ui/health_globe",
        .fill_sprite_id = "ui/health_globe",
        .screen_position = ball.position(),
        .width = health_globe_ball_size,
        .height = health_globe_ball_size,
        .fill_fraction = if (player.getEffectiveMaxHealth() == 0)
            0
        else
            @as(f32, @floatFromInt(player.current_health)) /
                @as(f32, @floatFromInt(player.getEffectiveMaxHealth())),
        .fill_direction = .up,
        .background_color = c_globe_bg,
        .fill_color = c_globe_fill,
        .tooltip = .{ .header = try spanRow(allocator, text(
            try std.fmt.allocPrint(allocator, "{d} / {d}", .{ player.current_health, player.getEffectiveMaxHealth() }),
        )) },
    } });
    // Stylized border drawn over the globe at its native size, centered on the
    // cell (co-registered with the ball). Slightly wider than the cell, so it
    // overhangs horizontally. Hover passes through to the globe.
    const border = health_cell.placeCenter(health_globe_border_width, health_globe_border_height);
    try elements.append(allocator, .{ .image = .{
        .sprite_id = "ui/health_globe_border",
        .screen_position = border.position(),
        .width = health_globe_border_width,
        .height = health_globe_border_height,
        .color = c_border,
        .blocks_input = false,
    } });

    // Current-health number centered on the ball, outlined for readability
    // over the fill. Passes hover through to the globe (the tooltip shows
    // `current / max`). Drawn AFTER the border so it sits on top of both.
    {
        const health_text = try std.fmt.allocPrint(allocator, "{d}", .{player.current_health});
        const label_width = font_metrics.measureSpanWidth(text(health_text), overlay_font_size);
        const label_box = ball.placeCenter(label_width, overlay_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = health_text,
            .screen_position = label_box.position(),
            .font_size = overlay_font_size,
            .outlined = true,
            .blocks_input = false,
        } });
    }

    // Weapon skills sub-bar (slots 1-3, packed flush).
    const weapon_sub_bar = row.next(weapon_skills_width);
    {
        var inner = Row.init(weapon_sub_bar.position(), bottom_bar_height, 0);
        var slot: u8 = 1;
        while (slot <= 3) : (slot += 1) {
            // Weapon-skill slots are derived from the equipped weapon — not
            // reorderable, so no drag ref.
            try emitSkillButton(elements, allocator, font_metrics, inner.next(slot_size), slot, player, weapon_type_definitions, c_border, c_icon, prepared_skill, active_theme.darkest, null, drag_source);
        }
    }

    // Weapon swap button (128, centered vertically in its cell).
    {
        const cell = row.next(swap_button_size);
        try elements.append(allocator, .{ .button = .{
            .sprite_id = "ui/icon_swap",
            .screen_position = cell.placeCenter(swap_button_size, swap_button_size).position(),
            .width = swap_button_size,
            .height = swap_button_size,
            .action = .swap_weapons,
            .color = c_border,
            .tooltip = .{ .header = try spanRow(allocator, text("Swap weapons")) },
        } });
    }

    // Utility skills sub-bar (slots 4-8, packed flush).
    const utility_sub_bar = row.next(utility_skills_width);
    {
        var inner = Row.init(utility_sub_bar.position(), bottom_bar_height, 0);
        var slot: u8 = 4;
        while (slot <= 8) : (slot += 1) {
            // Utility-skill slots are reorderable by drag: ref = skill_bar
            // index 0-4 (slot 4 → index 0, ..., slot 8 → index 4).
            try emitSkillButton(elements, allocator, font_metrics, inner.next(slot_size), slot, player, weapon_type_definitions, c_border, c_icon, prepared_skill, active_theme.darkest, .{ .skill_bar = @as(u32, slot - 4) }, drag_source);
        }
    }

    // Skip button — levels only.
    var skip_cell: ?Rectangle = null;
    if (in_level) {
        const cell = row.next(slot_size);
        skip_cell = cell;
        try emitIconButton(
            elements,
            allocator,
            cell,
            button_background_sprite_id,
            "ui/icon_skip",
            .skip,
            .{ .header = try spanRow(allocator, text("Skip turn step")) },
            c_skip_bg,
            c_icon,
            false,
            null,
        );
    }

    // --- Indicators above the bar (16px gap, 128×128) ---

    // Momentum: centered above the health globe (levels only).
    if (in_level) {
        const momentum_cell = health_cell
            .placeTopCenter(small_icon_size, small_icon_size, 0)
            .translate(0, -(ui_gap + small_icon_size));
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/momentum",
            .screen_position = momentum_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .tooltip = .{
                .header = try spanRow(allocator, text(
                    try std.fmt.allocPrint(allocator, "{d} momentum", .{player.momentum}),
                )),
                .body = try allocator.dupe(TooltipRow, &.{
                    try spanRow(allocator, text(
                        try std.fmt.allocPrint(allocator, "+{d} damage", .{player.getConvertedMomentum()}),
                    )),
                }),
            },
        } });
        try emitCenteredNumber(elements, allocator, font_metrics, momentum_cell, player.momentum, overlay_font_size);
    }

    // Active effects: flush 128 grid spanning the skill bars, filling
    // right-to-left (oldest rightmost) then wrapping upward.
    if (player.active_effects.len > 0) {
        const span_right = utility_sub_bar.right();
        const span_width = utility_sub_bar.right() - weapon_sub_bar.x;
        const columns = @max(1, @divFloor(span_width, small_icon_size));
        const bottom_row_top = bar.y - ui_gap - small_icon_size;
        for (player.active_effects, 0..) |effect, index| {
            const ordinal: i32 = @intCast(index);
            const column = @mod(ordinal, columns);
            const grid_row = @divFloor(ordinal, columns);
            const cell: Rectangle = .{
                .x = span_right - (column + 1) * small_icon_size,
                .y = bottom_row_top - grid_row * small_icon_size,
                .width = small_icon_size,
                .height = small_icon_size,
            };
            const definition = lookups.getEffectDefinition(effect.effect_id);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = effectIconSpriteId(effect.effect_id, definition),
                .screen_position = cell.position(),
                .width = small_icon_size,
                .height = small_icon_size,
                .color = c_icon,
                .tooltip = .{
                    .header = try spanRow(allocator, text(definition.name)),
                    .body = try allocator.dupe(TooltipRow, &.{
                        try spanRow(allocator, text(definition.description)),
                        try spanRow(allocator, text(
                            try std.fmt.allocPrint(allocator, "Current duration {d}", .{effect.duration}),
                        )),
                    }),
                },
            } });
            try emitCornerNumber(elements, allocator, font_metrics, cell, effect.duration);
        }
    }

    // Turn-step icons: move + attack above the skip button (levels only),
    // combined width equal to the skip button. The current phase is
    // highlighted; neither is highlighted during enemy turns.
    if (skip_cell) |skip| {
        const turn_phase = if (game_state.level) |level| level.turn_phase else null;
        const strip: Rectangle = .{
            .x = skip.x,
            .y = bar.y - ui_gap - small_icon_size,
            .width = skip.width,
            .height = small_icon_size,
        };
        var inner = Row.init(strip.position(), small_icon_size, 0);
        const move_cell = inner.next(small_icon_size);
        const attack_cell = inner.next(small_icon_size);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/turn_move",
            .screen_position = move_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .highlighted = turn_phase == .player_move,
            .tooltip = .{ .header = try spanRow(allocator, text("Move step")) },
        } });
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/turn_attack",
            .screen_position = attack_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .highlighted = turn_phase == .player_attack,
            .tooltip = .{ .header = try spanRow(allocator, text("Attack step")) },
        } });
    }
}

// ============================================================
// Editor bottom bar (tool palette)
// ============================================================

/// The centered utility-skill picker (the picker framework's first
/// consumer — see DESIGN → Architecture → Level Editor → Editor UI
/// layout). A modal panel: the None option + one cell per
/// utility-eligible skill (the flat list from src/utility_skills.zig —
/// weapon skills are never offered), 4-wide skill-button cells with the
/// icon + name; the currently-assigned skill is highlighted; a close
/// button top-right (the middle-panel convention). `target` names the
/// slot being assigned.
pub fn buildEditorSkillPicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    target: EditorPickerTarget,
    active_theme: types.ActiveColorTheme,
) !void {
    const slot_index = switch (target) {
        .utility_skill_slot => |index| index,
        // The sprite/footprint/theme targets aren't this picker's (the
        // view dispatches on the target); defensive for crafted calls.
        .entity_sprite, .decoration_sprite, .entity_layer, .decoration_layer, .decoration_footprint, .level_gradient => return,
    };
    var current: ?types.SkillId = null;
    if (slot_index < types.utility_skill_count) {
        current = switch (editorInspectorTarget(editor)) {
            .entity_type => |type_index| if (type_index < editor.entity_types.len)
                editor.entity_types[type_index].template.equipped_utility_skills[slot_index]
            else
                null,
            .player => editor.player_def.template.equipped_utility_skills[slot_index],
            // No utility-skill row in the decoration or item content —
            // nothing to show as current (defensive; the picker never
            // opens on either).
            .decoration_type, .item_type => null,
        };
    }

    // The FIXED picker overlay (the band between the sidebars) + a
    // FIXED-SIZE grid: 6 columns of `slot_size` cells, centered in the
    // area below the header (top-aligned if it ever outgrows it). The
    // overlay never resizes with its content — see
    // `editorPickerOverlayRect`.
    const options: i32 = @intCast(1 + utility_skills.utility_skill_ids.len); // None + skills
    const columns: i32 = 6;
    const rows: i32 = @divTrunc(options + columns - 1, columns);
    const cell = slot_size;
    const bounds = editorPickerOverlayRect();

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
    } });
    const title = try std.fmt.allocPrint(allocator, "Assign Slot {d}", .{slot_index + 4});
    const content = try emitPanelHeader(elements, allocator, bounds, title, .close_editor_picker);

    // The entity-inspect panel's skill coloring convention: frame at the
    // team gradient's index 3, icon at index 1 — the enemy gradient here
    // (the picker edits an enemy type).
    const enemy = active_theme.enemy_gradient.colors;
    const skill_frame_color = enemy[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const skill_icon_color = enemy[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const grid_width = columns * cell + (columns - 1) * ui_gap;
    const grid_height = rows * cell + (rows - 1) * ui_gap;
    const grid_origin: ScreenPosition = .{
        .x = content.x + @divFloor(content.width - grid_width, 2),
        .y = content.y + @max(ui_gap, @divFloor(content.height - grid_height, 2)),
    };

    // Cell 0: the None option (clears the slot) — no editor_skill payload;
    // the one cell that carries a text label.
    try emitPickerSkillCell(
        elements,
        allocator,
        font_metrics,
        .{ .x = grid_origin.x, .y = grid_origin.y, .width = cell, .height = cell },
        null,
        "None",
        "ui/skill_slot_empty",
        current == null,
        skill_frame_color,
        skill_icon_color,
        active_theme.lightest,
    );
    // One cell per utility skill, in enum order (index + 1: cell 0 is
    // None). Icon-only — the icon is the identity at full cell size; the
    // tooltip carries the name.
    for (utility_skills.utility_skill_ids, 0..) |skill_id, index| {
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        const column: i32 = @intCast((index + 1) % @as(usize, @intCast(columns)));
        const row: i32 = @intCast((index + 1) / @as(usize, @intCast(columns)));
        const cell_rect: Rectangle = .{
            .x = grid_origin.x + column * (cell + ui_gap),
            .y = grid_origin.y + row * (cell + ui_gap),
            .width = cell,
            .height = cell,
        };
        try emitPickerSkillCell(
            elements,
            allocator,
            font_metrics,
            cell_rect,
            skill_id,
            definition.name,
            "ui/skill_button",
            current == skill_id,
            skill_frame_color,
            skill_icon_color,
            active_theme.lightest,
        );
    }
}

/// The centered SPRITE picker (the picker framework's second consumer):
/// pick the edited entity type's base sprite. Two tabs top-left — Mission
/// (the .pngs scanned from the mission directory, stored as namespaced
/// `custom/<mission-dir>/<stem>` ids) and Official (the shipped entity
/// sprites, minus the player body); close top-right. One 256×256 cell per
/// option (the palette tool-cell look). Dropdown semantics like the skill
/// picker: blocks only where it sits, stays open until a pick or close.
/// No scrolling — 6 fixed columns, all rows (overflow is a follow-up if
/// real content needs it).
pub fn buildEditorSpritePicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    mission_sprites: []const []const u8,
    decoration_registry: []const types.DecorationTypeDef,
    picker_target: EditorPickerTarget,
    tab: types.EditorSpritePickerTab,
) !void {
    // What the picker is picking: a BASE sprite (entity / decoration) or
    // a LAYER sprite (entity / decoration — the layer index rides the
    // picker target, null = add-new; the skill picker's slot pattern).
    // The base modes resolve through the inspector target; a skill-slot
    // target is the skill picker's own builder (the view dispatches).
    const PickerKind = enum { entity_base, decoration_base, entity_layer, decoration_layer };
    const picker_kind: PickerKind = switch (picker_target) {
        .utility_skill_slot, .decoration_footprint, .level_gradient => return,
        .entity_sprite => .entity_base,
        .decoration_sprite => .decoration_base,
        .entity_layer => .entity_layer,
        .decoration_layer => .decoration_layer,
    };
    const layer_mode = picker_kind == .entity_layer or picker_kind == .decoration_layer;
    const layer_index: ?u32 = switch (picker_target) {
        .entity_layer => |index| index,
        .decoration_layer => |index| index,
        else => null,
    };

    // The edited definition (highlight target + tint source) — the target
    // resolution's single seam, same as the skill picker. Entity content
    // tints with the enemy gradient; decoration content with the WORLD
    // gradient (the in-game decoration tinting). The player target keeps
    // the entity shape (the player has no sprite/layer rows, so the
    // picker only opens on it via a stale open — picks commit nothing).
    // The item target has no sprite either — nothing to pick (defensive;
    // the picker never opens on it).
    const target = editorInspectorTarget(editor);
    if (target == .item_type) return;
    const entity_context: ?InspectorEntityContext = switch (target) {
        .entity_type => |index| .{
            .template = editor.entity_types[index].template,
            .edit_target = .{ .entity_type = index },
            .gradient_colors = active_theme.enemy_gradient.colors,
        },
        .player => .{
            .template = editor.player_def.template,
            .edit_target = .player_def,
            .gradient_colors = active_theme.player_gradient.colors,
        },
        .decoration_type, .item_type => null,
    };
    const decoration_context: ?InspectorDecorationContext = switch (target) {
        .decoration_type => |index| .{
            .type_definition = editor.decoration_types[index],
        },
        .entity_type, .player, .item_type => null,
    };
    const base_sprite: []const u8 = if (decoration_context) |context|
        context.type_definition.sprite
    else
        entity_context.?.template.sprite;
    const base_color_index: u32 = if (decoration_context) |context|
        context.type_definition.color_index
    else
        entity_context.?.template.color_index;
    // In layer-EDIT mode the edited layer is the highlight target + tint
    // source; ADD mode highlights nothing and tints with the base. A
    // stale state — the layer index out of range, or the picker kind
    // mismatched with the target (the tool switched mid-open; the
    // dropdown stays open by design) — also falls back to the base
    // values, and every pick no-ops at the commit gate.
    const edited_layer_sprite: ?[]const u8 = blk: {
        const index = layer_index orelse break :blk null;
        if (picker_kind == .entity_layer) {
            const context = entity_context orelse break :blk null;
            if (index >= context.template.layers.len) break :blk null;
            break :blk context.template.layers[index].sprite;
        }
        const context = decoration_context orelse break :blk null;
        if (index >= context.type_definition.layers.len) break :blk null;
        break :blk context.type_definition.layers[index].sprite;
    };
    const edited_layer_color_index: ?u32 = blk: {
        const index = layer_index orelse break :blk null;
        if (picker_kind == .entity_layer) {
            const context = entity_context orelse break :blk null;
            if (index >= context.template.layers.len) break :blk null;
            break :blk context.template.layers[index].color_index;
        }
        const context = decoration_context orelse break :blk null;
        if (index >= context.type_definition.layers.len) break :blk null;
        break :blk context.type_definition.layers[index].color_index;
    };
    const gradient = if (picker_kind == .decoration_base or picker_kind == .decoration_layer)
        active_theme.world_gradient.colors
    else
        active_theme.enemy_gradient.colors;
    const current_sprite: ?[]const u8 = if (layer_mode) edited_layer_sprite else base_sprite;
    const current_color_index: u32 = edited_layer_color_index orelse base_color_index;
    const graphic_color = gradient[@min(current_color_index, types.gradient_color_count - 1)];
    const button_color = gradient[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const pick_action: types.Action = switch (picker_kind) {
        .entity_base => .select_editor_entity_sprite,
        .decoration_base => .select_editor_decoration_sprite,
        .entity_layer => .select_editor_entity_layer,
        .decoration_layer => .select_editor_decoration_layer,
    };

    // One cell per offered sprite, built per frame into the frame arena:
    // the stored id (a bare stem or a namespaced `custom/<mission>/<stem>`),
    // the cell label, the renderable graphic (null = a text-only cell —
    // custom art isn't renderable yet), and the graphic's aspect-fit
    // frame. The Official tab's list differs per kind: the shipped entity
    // sprites (base + layer — a layer may be any entity art, the fixed
    // 512×640 frame), the registry prefabs (decoration base — each pick
    // adopts the whole prefab), or the shipped decoration sprites
    // FILTERED to the base type's dims (decoration layers must match
    // their base — the load-time invariant; mismatched art is never
    // offered). Mission-local art is the same list for every kind (dims
    // are checked at the pick commit).
    const PickerCell = struct {
        stored_id: []const u8,
        label: []const u8,
        graphic_id: ?[]const u8,
        frame_width: i32,
        frame_height: i32,
    };
    var cells: std.ArrayList(PickerCell) = .empty;
    const mission_directory = missionDirectoryName(editor.mission.path);
    switch (tab) {
        .mission_local => {
            for (mission_sprites) |file_name| {
                const stem = file_name[0 .. std.mem.lastIndexOfScalar(u8, file_name, '.') orelse file_name.len];
                try cells.append(allocator, .{
                    .stored_id = try std.fmt.allocPrint(
                        allocator,
                        "custom/{s}/{s}",
                        .{ mission_directory, stem },
                    ),
                    .label = stem,
                    .graphic_id = null,
                    .frame_width = editor_entity_frame_width,
                    .frame_height = editor_entity_frame_height,
                });
            }
        },
        .official => switch (picker_kind) {
            .entity_base, .entity_layer => {
                for (official_entity_sprite_stems) |stem| {
                    try cells.append(allocator, .{
                        .stored_id = stem,
                        .label = stem,
                        .graphic_id = try std.fmt.allocPrint(allocator, "entities/{s}", .{stem}),
                        .frame_width = editor_entity_frame_width,
                        .frame_height = editor_entity_frame_height,
                    });
                }
            },
            .decoration_base => {
                for (decoration_registry) |definition| {
                    try cells.append(allocator, .{
                        .stored_id = definition.sprite,
                        .label = definition.sprite,
                        .graphic_id = try std.fmt.allocPrint(
                            allocator,
                            "decorations/{s}",
                            .{definition.sprite},
                        ),
                        .frame_width = definition.pixel_dims.x,
                        .frame_height = definition.pixel_dims.y,
                    });
                }
            },
            .decoration_layer => {
                // A stale open on a non-decoration target: no base dims to
                // match against — no cells ("No sprites"), picks no-op.
                if (decoration_context) |context| {
                    const base_dims = context.type_definition.pixel_dims;
                    for (official_decoration_sprites) |sprite| {
                        if (sprite.width != base_dims.x or sprite.height != base_dims.y) continue;
                        try cells.append(allocator, .{
                            .stored_id = sprite.stem,
                            .label = sprite.stem,
                            .graphic_id = try std.fmt.allocPrint(
                                allocator,
                                "decorations/{s}",
                                .{sprite.stem},
                            ),
                            .frame_width = sprite.width,
                            .frame_height = sprite.height,
                        });
                    }
                }
            },
        },
    }
    // The FIXED picker overlay (the band between the sidebars) + a
    // FIXED-SIZE grid: 6 columns of `slot_size` cells, centered in the
    // area below the header (top-aligned if it ever outgrows it). The
    // overlay never resizes with its content — see
    // `editorPickerOverlayRect`.
    const columns: i32 = 6;
    const rows: i32 = @max(@divTrunc(@as(i32, @intCast(cells.items.len)) + columns - 1, columns), 1);
    const cell = slot_size;
    const bounds = editorPickerOverlayRect();

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
    } });

    // The header: tab buttons top-left, close top-right (no title — the
    // tabs ARE the header). Tab state is UiState (a view affordance).
    const origin = bounds.position();
    const tab_specs = [_]struct { tab: types.EditorSpritePickerTab, label: []const u8 }{
        .{ .tab = .mission_local, .label = "Mission" },
        .{ .tab = .official, .label = "Official" },
    };
    var tab_x = origin.x + ui_gap;
    for (tab_specs) |spec| {
        const label_width = font_metrics.measureSpanWidth(text(spec.label), middle_panel_header_font_size);
        const tab_width = label_width + 2 * ui_gap;
        const active = spec.tab == tab;
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = .{ .x = tab_x, .y = origin.y },
            .width = tab_width,
            .height = middle_panel_header_height,
            // Darkest always (the background-panel class) — the active
            // tab's highlight outline is the indication, no tint change.
            .color = active_theme.darkest,
        } });
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{ .x = tab_x, .y = origin.y },
            .width = tab_width,
            .height = middle_panel_header_height,
            .action = .select_editor_sprite_tab,
            .editor_sprite_tab = spec.tab,
            .highlighted = active,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = spec.label,
            .screen_position = .{
                .x = tab_x + ui_gap,
                .y = origin.y + @divFloor(middle_panel_header_height - middle_panel_header_font_size, 2),
            },
            .font_size = middle_panel_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        tab_x += tab_width + ui_gap;
    }
    try elements.append(allocator, .{ .button = .{
        .sprite_id = close_button_sprite_id,
        .screen_position = .{
            .x = origin.x + bounds.width - close_button_size,
            .y = origin.y,
        },
        .width = close_button_size,
        .height = close_button_size,
        .action = .close_editor_picker,
    } });
    const content: Rectangle = .{
        .x = bounds.x,
        .y = bounds.y + middle_panel_header_height,
        .width = bounds.width,
        .height = bounds.height - middle_panel_header_height,
    };

    // The edited template's colors were resolved above (the target's
    // single seam) — nothing further to derive here. The grid is centered
    // horizontally (fixed 6-column width), top-anchored below the header
    // with the vertical centering clamp.
    const grid_width = columns * cell + (columns - 1) * ui_gap;
    const grid_height = rows * cell + (rows - 1) * ui_gap;
    const grid_origin: ScreenPosition = .{
        .x = content.x + @divFloor(content.width - grid_width, 2),
        .y = content.y + @max(ui_gap, @divFloor(content.height - grid_height, 2)),
    };

    if (cells.items.len == 0) {
        try elements.append(allocator, .{ .text_label = .{
            .text = "No sprites",
            .screen_position = grid_origin,
            .font_size = editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        return;
    }

    for (cells.items, 0..) |picker_cell, index| {
        const column: i32 = @intCast(index % @as(usize, @intCast(columns)));
        const row: i32 = @intCast(index / @as(usize, @intCast(columns)));
        const cell_rect: Rectangle = .{
            .x = grid_origin.x + column * (cell + ui_gap),
            .y = grid_origin.y + row * (cell + ui_gap),
            .width = cell,
            .height = cell,
        };
        // Nothing highlighted in layer-ADD mode (no current layer); a
        // stale layer index likewise highlights nothing.
        const highlighted = if (current_sprite) |sprite|
            std.mem.eql(u8, sprite, picker_cell.stored_id)
        else
            false;
        try emitPickerSpriteCell(
            elements,
            allocator,
            font_metrics,
            cell_rect,
            picker_cell.stored_id,
            picker_cell.label,
            picker_cell.graphic_id,
            graphic_color,
            button_color,
            highlighted,
            active_theme.lightest,
            pick_action,
            picker_cell.frame_width,
            picker_cell.frame_height,
        );
    }
}

/// The decoration FOOTPRINT editor (the `.decoration_footprint` picker):
/// a centered panel showing the type's sprite FULL-SIZE (1:1 — 256 screen
/// px per sprite-grid tile) with one toggleable cell per tile, a
/// continuous WHITE outline around the draft-selected region (the
/// placement preview's region-edge style — 8px bars centered on the
/// boundary, seamless at corners), a close button top-right (discard),
/// and a Confirm button bottom-center. The draft rides
/// `UiState.editor_footprint_draft`; the type id rides the picker target
/// (see the union). Custom-stem art isn't renderable yet — its cells get
/// a dark fill so the grid stays visible.
/// The metadata sidebar's THEME PICKER (the `.level_gradient` target):
/// a centered panel listing every gradient in `color_themes.txt` as a
/// full-width swatch strip — one row per gradient, bare strips (no
/// labels — the colors ARE the content), a close button top-right. The
/// row for the level's CURRENT index (the world pick, or the override —
/// the DERIVED index while a role is on auto) carries a lightest frame
/// (the unified 8px outline convention). A pick commits through the
/// slice-1 player wrappers (same-value picks close without recording;
/// an auto-role pick flips it to manual — see the input arm). Dropdown
/// semantics like every editor picker: blocks only where it sits.
pub fn buildEditorThemePicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    color_theme_definitions: types.ColorThemeDefinitions,
    active_theme: types.ActiveColorTheme,
    target: struct { level_index: u32, role: types.LevelGradientRole },
) !void {
    _ = font_metrics;
    const gradients = color_theme_definitions.gradients;
    // FIXED-SIZE rows: full-gradient strips at 6 × `slot_size` blocks
    // (1536 wide, one row of `slot_size` height), centered in the FIXED
    // picker overlay (the band between the sidebars) — the overlay never
    // resizes with the wheel's gradient count. See
    // `editorPickerOverlayRect`.
    const row_height = slot_size;
    const strip_width = types.gradient_color_count * slot_size;
    const rows: i32 = @intCast(gradients.len);
    const grid_height = rows * row_height + @max(rows - 1, 0) * ui_gap;
    const bounds = editorPickerOverlayRect();

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
    } });
    const title = try std.fmt.allocPrint(allocator, "Pick {s}", .{switch (target.role) {
        .world => "World colors",
        .enemy => "Enemy colors",
        .player => "Player colors",
    }});
    const content = try emitPanelHeader(elements, allocator, bounds, title, .close_editor_picker);
    const rows_origin_y = content.y + @max(ui_gap, @divFloor(content.height - grid_height, 2));

    // The level's current index for the role (the DERIVED one while an
    // enemy/player role is on auto — it's what's in effect). A stale
    // level index (defensive; picks gate at the input layer) highlights
    // nothing.
    var current_index: ?u32 = null;
    if (target.level_index < editor.levels.len) {
        const level = editor.levels[target.level_index];
        current_index = switch (target.role) {
            .world => level.color_wheel_index,
            .enemy => level.enemy_gradient_index orelse
                loaders.autoDerivedGradientIndex(color_theme_definitions, level.color_wheel_index, .enemy),
            .player => level.player_gradient_index orelse
                loaders.autoDerivedGradientIndex(color_theme_definitions, level.color_wheel_index, .player),
        };
    }

    for (gradients, 0..) |gradient, index| {
        const row_rect: Rectangle = .{
            .x = content.x + @divFloor(content.width - strip_width, 2),
            .y = rows_origin_y + @as(i32, @intCast(index)) * (row_height + ui_gap),
            .width = strip_width,
            .height = row_height,
        };
        const block_width = @divFloor(row_rect.width, types.gradient_color_count);
        for (0..types.gradient_color_count) |color_index| {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{
                    .x = row_rect.x + @as(i32, @intCast(color_index)) * block_width,
                    .y = row_rect.y,
                },
                .width = block_width,
                .height = row_rect.height,
                .color = gradient.colors[color_index],
            } });
        }
        try elements.append(allocator, .{ .button = .{
            .screen_position = row_rect.position(),
            .width = row_rect.width,
            .height = row_rect.height,
            .action = .select_editor_level_gradient,
            .editor_gradient = @intCast(index),
            .highlighted = current_index != null and current_index.? == index,
        } });
        // A VISIBLE current marker (Button.highlighted doesn't render —
        // see TODO): a lightest frame around the current row, the unified
        // 8px outline convention.
        if (current_index != null and current_index.? == index) {
            const thickness: i32 = 8;
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = row_rect.x, .y = row_rect.y },
                .width = row_rect.width,
                .height = thickness,
                .color = active_theme.lightest,
            } });
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = row_rect.x, .y = row_rect.y + row_rect.height - thickness },
                .width = row_rect.width,
                .height = thickness,
                .color = active_theme.lightest,
            } });
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = row_rect.x, .y = row_rect.y },
                .width = thickness,
                .height = row_rect.height,
                .color = active_theme.lightest,
            } });
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = row_rect.x + row_rect.width - thickness, .y = row_rect.y },
                .width = thickness,
                .height = row_rect.height,
                .color = active_theme.lightest,
            } });
        }
    }
}

pub fn buildEditorFootprintEditor(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    type_id: u32,
    ui_state: *const UiState,
) !void {
    // The type deleted mid-edit (or a stale open): nothing to edit —
    // the panel vanishes; the close button is unreachable, so the input
    // arms' own guards are the real defense (the toggle no-ops on an
    // out-of-range type).
    if (type_id >= editor.decoration_types.len) return;
    const definition = editor.decoration_types[type_id];
    const grid_width: i32 = @divTrunc(definition.pixel_dims.x + 255, 256);
    const grid_height: i32 = @divTrunc(definition.pixel_dims.y + 255, 256);
    if (grid_width <= 0 or grid_height <= 0) return;
    const cell_count: usize = @intCast(grid_width * grid_height);
    if (cell_count > editor_footprint_grid_cell_limit) return;

    // The FIXED picker overlay (the band between the sidebars). The grid
    // SCALES DOWN to fit the area between the header and the Confirm
    // button (never upscaled — 1:1 is the design size; an 8×8 custom
    // sprite is the case that shrinks). See `editorPickerOverlayRect`.
    const tile: i32 = 256;
    const header_height = middle_panel_header_height;
    const confirm_height = editor_inspector_row_height;
    const bounds = editorPickerOverlayRect();
    const avail_width = bounds.width - 2 * ui_gap;
    const avail_height = bounds.height - header_height - confirm_height - 3 * ui_gap;
    const scale: f32 = @min(
        @as(f32, 1.0),
        @min(
            @as(f32, @floatFromInt(avail_width)) / @as(f32, @floatFromInt(grid_width * tile)),
            @as(f32, @floatFromInt(avail_height)) / @as(f32, @floatFromInt(grid_height * tile)),
        ),
    );
    const scaled_tile: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(tile)) * scale)));
    const grid_width_pixels = grid_width * scaled_tile;
    const grid_height_pixels = grid_height * scaled_tile;

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
    } });

    // The header: title left, close right (the sprite picker's idiom).
    const origin = bounds.position();
    try elements.append(allocator, .{ .text_label = .{
        .text = "Footprint",
        .screen_position = .{
            .x = origin.x + ui_gap,
            .y = origin.y + @divFloor(header_height - middle_panel_header_font_size, 2),
        },
        .font_size = middle_panel_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = close_button_sprite_id,
        .screen_position = .{
            .x = origin.x + bounds.width - close_button_size,
            .y = origin.y,
        },
        .width = close_button_size,
        .height = close_button_size,
        .action = .close_editor_picker,
    } });

    // The sprite grid: the art SCALED, centered in the area between the
    // header and the Confirm button; custom stems get a dark fill per
    // cell so the grid stays visible without art.
    const grid_origin: ScreenPosition = .{
        .x = origin.x + @divFloor(bounds.width - grid_width_pixels, 2),
        .y = origin.y + header_height + ui_gap +
            @divFloor(avail_height - grid_height_pixels, 2),
    };
    if (std.mem.startsWith(u8, definition.sprite, "custom/")) {
        for (0..cell_count) |cell_index| {
            const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
            const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{
                    .x = grid_origin.x + column * tile,
                    .y = grid_origin.y + row * tile,
                },
                .width = tile,
                .height = tile,
                .color = .{ .r = 40, .g = 40, .b = 40 },
            } });
        }
    } else {
        const graphic_id = try std.fmt.allocPrint(allocator, "decorations/{s}", .{definition.sprite});
        const scaled_width: i32 = @max(1, @as(i32, @intFromFloat(
            @as(f32, @floatFromInt(definition.pixel_dims.x)) * scale,
        )));
        const scaled_height: i32 = @max(1, @as(i32, @intFromFloat(
            @as(f32, @floatFromInt(definition.pixel_dims.y)) * scale,
        )));
        try elements.append(allocator, .{ .image = .{
            .sprite_id = graphic_id,
            .screen_position = grid_origin,
            .width = scaled_width,
            .height = scaled_height,
            .color = default_tint,
            .blocks_input = false,
        } });
    }

    // One invisible toggle button per grid cell (the draft flips at the
    // input site — a direct UiState write, off the undo timeline).
    for (0..cell_count) |cell_index| {
        const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
        const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{
                .x = grid_origin.x + column * scaled_tile,
                .y = grid_origin.y + row * scaled_tile,
            },
            .width = scaled_tile,
            .height = scaled_tile,
            .action = .toggle_editor_footprint_tile,
            .editor_footprint_tile = @intCast(cell_index),
        } });
    }

    // The draft-selected region's outline: one 8px bar per boundary side
    // (the neighbor across it unselected or off-grid), centered on the
    // boundary — the editor's region-edge outline, in white, so corners
    // join seamlessly for any shape.
    const outline_thickness: i32 = 8;
    const half_thickness: i32 = @divFloor(outline_thickness, 2);
    const draftSelected = struct {
        fn check(
            draft: *const [editor_footprint_grid_cell_limit]bool,
            grid_width_: i32,
            grid_height_: i32,
            x: i32,
            y: i32,
        ) bool {
            if (x < 0 or y < 0 or x >= grid_width_ or y >= grid_height_) return false;
            return draft[@intCast(y * grid_width_ + x)];
        }
    }.check;
    for (0..cell_count) |cell_index| {
        if (!ui_state.editor_footprint_draft[cell_index]) continue;
        const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
        const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
        const cell_x = grid_origin.x + column * scaled_tile;
        const cell_y = grid_origin.y + row * scaled_tile;
        const draft = &ui_state.editor_footprint_draft;
        if (!draftSelected(draft, grid_width, grid_height, column, row - 1)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x, .y = cell_y - half_thickness },
                .width = scaled_tile,
                .height = outline_thickness,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column, row + 1)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x, .y = cell_y + scaled_tile - half_thickness },
                .width = scaled_tile,
                .height = outline_thickness,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column - 1, row)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x - half_thickness, .y = cell_y },
                .width = outline_thickness,
                .height = scaled_tile,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column + 1, row)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x + scaled_tile - half_thickness, .y = cell_y },
                .width = outline_thickness,
                .height = scaled_tile,
                .color = default_tint,
            } });
        }
    }

    // The Confirm button (bottom-center of the overlay, the layer-button
    // visual class) — a FIXED position now (the grid scales above it).
    const confirm_rect: Rectangle = .{
        .x = origin.x + @divFloor(bounds.width - @divFloor(bounds.width, 2), 2),
        .y = origin.y + bounds.height - confirm_height - ui_gap,
        .width = @divFloor(bounds.width, 2),
        .height = confirm_height,
    };
    try emitInspectorLayerButton(
        elements,
        allocator,
        font_metrics,
        confirm_rect,
        "Confirm",
        .confirm_editor_footprint,
        null,
        active_theme.world_gradient.colors[@min(@as(u32, 5), types.gradient_color_count - 1)],
        active_theme.lightest,
    );
}

/// The mission directory's NAME (the last path segment) — the namespace
/// for mission-local sprite ids.
fn missionDirectoryName(mission_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, mission_path, '/')) |slash| {
        return mission_path[slash + 1 ..];
    }
    return mission_path;
}

/// One sprite-picker cell: the button background (carrying the pick + the
/// stored-id payload) + the option's graphic. Official options draw the
/// sprite; mission-local options carry a text label (their art isn't
/// renderable until custom-asset rendering lands).
fn emitPickerSpriteCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell_rect: Rectangle,
    sprite_id: []const u8,
    label: []const u8,
    graphic_sprite_id: ?[]const u8,
    graphic_color: Color,
    button_color: Color,
    highlighted: bool,
    label_color: Color,
    pick_action: types.Action,
    frame_width: i32,
    frame_height: i32,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = button_background_sprite_id,
        .screen_position = cell_rect.position(),
        .width = cell_rect.width,
        .height = cell_rect.height,
        .action = pick_action,
        .editor_sprite = sprite_id,
        .color = button_color,
        .highlighted = highlighted,
        .tooltip = .{ .header = try spanRow(allocator, text(label)) },
    } });
    if (graphic_sprite_id) |graphic_id| {
        const fitted = scaleToFit(cell_rect, frame_width, frame_height);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = graphic_id,
            .screen_position = fitted.position(),
            .width = fitted.width,
            .height = fitted.height,
            .color = graphic_color,
            .blocks_input = false,
        } });
    } else {
        const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = cell_rect
                .placeCenter(label_width, editor_group_header_font_size)
                .position(),
            .font_size = editor_group_header_font_size,
            .color = label_color,
            .blocks_input = false,
        } });
    }
}

/// One picker cell: the frame button (carrying the pick; null skill_id =
/// the None cell) + the skill icon at FULL cell size. Real skills are
/// icon-only (the tooltip carries the name); the None cell keeps its text
/// label.
fn emitPickerSkillCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell_rect: Rectangle,
    skill_id: ?types.SkillId,
    label: []const u8,
    frame_sprite_id: []const u8,
    highlighted: bool,
    frame_color: Color,
    icon_color: Color,
    label_color: Color,
) !void {
    const tooltip: ?Tooltip = if (skill_id) |some_id|
        if (lookups.getSkillDefinition(some_id)) |definition|
            try buildSkillTooltip(allocator, definition)
        else
            null
    else
        .{ .header = try spanRow(allocator, text("None")) };
    try elements.append(allocator, .{ .button = .{
        .sprite_id = frame_sprite_id,
        .screen_position = cell_rect.position(),
        .width = cell_rect.width,
        .height = cell_rect.height,
        .action = .select_editor_utility_skill,
        .editor_skill = skill_id,
        .color = frame_color,
        .highlighted = highlighted,
        .tooltip = tooltip,
    } });
    if (skill_id) |some_id| {
        // Full cell size — the icon is the identity.
        try elements.append(allocator, .{ .image = .{
            .sprite_id = skillIconSpriteId(some_id),
            .screen_position = cell_rect.position(),
            .width = cell_rect.width,
            .height = cell_rect.height,
            .color = icon_color,
            .blocks_input = false,
        } });
    } else {
        const font_size: i32 = 48;
        const label_width = font_metrics.measureSpanWidth(text(label), font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = cell_rect
                .placeBottomCenter(label_width, font_size, ui_gap)
                .position(),
            .font_size = font_size,
            .color = label_color,
            .blocks_input = false,
        } });
    }
}

pub const material_count_inset = ui_emit.material_count_inset;
const emitMaterialIcons = ui_emit.emitMaterialIcons;
const materialCount = ui_emit.materialCount;
const material_kinds = ui_emit.material_kinds;

/// The sprite id for a skill icon: `skills/<tag>` mirroring the SkillId tag
/// name (assets/skills/<tag>.png). Comptime-built per-variant table so the

/// The sprite id for an active-effect icon in the UI (bottom-bar effects
/// grid + entity-inspect panel). Effects created by a skill share the skill's
/// tag name (EffectId and SkillId overlap: `reflect`, `stone_form`,
/// `that_which_lingers`), so the skill's icon (`skills/<tag>`) is used —
/// the effect's own `effect_sprite` is a WORLD overlay (under
/// `assets/effects/`), not a UI icon. Non-skill effects without a
/// matching SkillId fall back to the effect-sprite path
/// (`effects/<effect_sprite>`) or the effect name (magenta placeholder).
fn effectIconSpriteId(effect_id: types.EffectId, definition: Effect) []const u8 {
    const tag = @tagName(effect_id);
    if (std.meta.stringToEnum(SkillId, tag)) |skill_id| {
        return skillIconSpriteId(skill_id);
    }
    if (definition.effect_sprite) |sprite| return sprite;
    return definition.name;
}

/// Render size for a slot's content, by domain. Inventory + gear slots are
/// 128×128 (`inventory_slot_size`); skill-bar + learned-skill slots are
/// 256×256 (`slot_size`). Pure function of the ref's domain.
pub fn slotContentSize(ref: SlotRef) i32 {
    return switch (ref) {
        .inventory, .gear => inventory_slot_size,
        .skill_bar, .learned_skill => slot_size,
        // Unreachable: save rows never start drags (slotContentIcon is
        // null for them). Size value is arbitrary.
        .save_file => slot_size,
    };
}

/// The content icon for a slot ref, resolved against the live player entity
/// (inventory/gear/skill-bar contents) or the skill-id tag (learned-skill
/// pool). Returns null for an empty slot — the caller must not start a drag
/// from an empty slot. This is the "what is actually being dragged" lookup,
/// distinct from a slot element's `icon_sprite_id` (which is the frame
/// background, always present).
pub fn slotContentIcon(game_state: *const GameState, ref: SlotRef) ?[]const u8 {
    const player = playerEntity(game_state) orelse return null;
    return switch (ref) {
        .inventory => |i| blk: {
            if (i >= player.inventory.slots.len) break :blk null;
            if (player.inventory.slots[i]) |item| break :blk itemIconSpriteId(item);
            break :blk null;
        },
        .gear => |g| switch (g) {
            .main_hand => if (player.main_hand_weapon) |w| itemIconSpriteId(.{ .weapon = w }) else null,
            .off_hand => if (player.off_hand_weapon) |w| itemIconSpriteId(.{ .weapon = w }) else null,
            .amulet => if (player.amulet) |a| itemIconSpriteId(.{ .amulet = a }) else null,
            .coat => if (player.coat) |c| itemIconSpriteId(.{ .coat = c }) else null,
            .gloves => if (player.gloves) |gv| itemIconSpriteId(.{ .gloves = gv }) else null,
            .pants => if (player.pants) |p| itemIconSpriteId(.{ .pants = p }) else null,
            .boots => if (player.boots) |b| itemIconSpriteId(.{ .boots = b }) else null,
        },
        .skill_bar => |i| blk: {
            if (i >= player.equipped_utility_skills.len) break :blk null;
            if (player.equipped_utility_skills[i]) |skill_id| break :blk skillIconSpriteId(skill_id);
            break :blk null;
        },
        .learned_skill => |skill_id| skillIconSpriteId(skill_id),
        // Save rows have no drag content — null here is what keeps the drag
        // machinery from ever starting on them (a press can't promote).
        .save_file => null,
    };
}

/// The Item in a gear slot, or null if empty. Used by panel builders for
/// item icons + tooltips. Mirrors the handler-side `gearSlotItem`.
pub fn gearSlotItem(player: Entity, gear_slot: GearSlot) ?types.Item {
    return player.gearSlotItem(gear_slot);
}

pub fn buildInventoryPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    inventory: types.Inventory,
    materials: types.Materials,
    learned_skills: []const types.SkillId,
    /// The player's equipped gear — baseline for item-tooltip stat
    /// comparisons. Null suppresses them.
    equipped: ?EquippedGear,
    active_theme: types.ActiveColorTheme,
    /// The slot currently being dragged from, if any. The item `Image` is
    /// suppressed on the source slot so the item reads as "in flight"
    /// (shown only as the drag ghost following the pointer). The frame +
    /// tooltip still emit (the tooltip is globally suppressed while a drag
    /// is active — see view.zig — so it's moot here, but the frame keeps
    /// the slot's hit-test identity intact).
    drag_source: ?SlotRef,
    /// Held keyboard modifiers this frame. Drives the salvage-tool indicator
    /// highlight (outlined while Shift is held).
    held_modifiers: types.Modifiers,
    /// In-progress shift-drag region selection, if any. Rendered as a lightest
    /// outline around the bounding box of the two corner slots.
    salvage_region: ?SalvageRegion,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Inventory", .toggle_inventory);

    const p = active_theme.player_gradient.colors;
    const slot_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    // Item icons render at player-gradient index 1.
    const item_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const grid = Grid{
        .origin = .{ .x = origin.x + ui_gap, .y = origin.y + ui_gap },
        .cell_width = inventory_slot_size,
        .cell_height = inventory_slot_size,
        .gap = 0,
        .columns = types.inventory_columns,
    };
    var index: i32 = 0;
    while (index < types.inventory_slot_count) : (index += 1) {
        const cell = grid.cell(index);
        // Slot frame. Carries the slot identity so press/click handlers
        // can resolve which slot was acted on (drag/drop + click intents).
        // When the slot holds an item, the tooltip rides on the frame: the
        // item Image on top is non-blocking, so `tooltipAt` falls through to
        // the Slot beneath (the blocking surface) — one tooltip target per
        // slot.
        const occupied_slot = inventory.slots[@intCast(index)];
        const slot_tooltip: ?Tooltip = if (occupied_slot) |item|
            try buildItemTooltip(allocator, item, learned_skills, equipped)
        else
            null;
        try elements.append(allocator, .{ .slot = .{
            .screen_position = cell.position(),
            .size = inventory_slot_size,
            .icon_sprite_id = "ui/item_slot",
            .icon_color = slot_color,
            .ref = .{ .inventory = @intCast(index) },
            .tooltip = slot_tooltip,
        } });
        // Item icon on top of the frame. Passes hover/click through to the
        // slot beneath so the slot stays the single interaction target.
        // Suppressed on the drag source: the item reads as "in flight"
        // (the drag ghost follows the pointer instead).
        const is_drag_source = if (drag_source) |src| switch (src) {
            .inventory => |si| si == @as(u32, @intCast(index)),
            else => false,
        } else false;
        if (!is_drag_source) {
            if (inventory.slots[@intCast(index)]) |item| {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = itemIconSpriteId(item),
                    .screen_position = cell.position(),
                    .width = inventory_slot_size,
                    .height = inventory_slot_size,
                    .color = item_color,
                    .blocks_input = false,
                } });
            }
        }
    }

    // Material sidebar: a 128-wide column to the right of the grid
    // (`ui_gap` between them). The five material icons stack bottom-aligned
    // — the stack's bottom edge aligns with the grid's bottom edge. Order
    // top-to-bottom: wood, metal, leather, cloth, knowledge, each tinted
    // with its fixed player-gradient index. Each icon carries an outlined
    // count label in its bottom-right corner.
    const sidebar_x = origin.x + ui_gap + types.inventory_columns * inventory_slot_size + ui_gap;
    const grid_top = origin.y + ui_gap;
    const grid_bottom = grid_top + types.inventory_rows * inventory_slot_size;
    const stack_height = @as(i32, material_kinds.len) * inventory_slot_size;
    const icon_top = grid_bottom - stack_height;
    try emitMaterialIcons(
        elements,
        allocator,
        font_metrics,
        .{ .x = sidebar_x, .y = icon_top },
        inventory_slot_size,
        .vertical,
        materials,
        active_theme,
    );

    // Salvage-tool indicator: top of the material sidebar column (the
    // materials are bottom-aligned, so the top of that column is empty).
    // Display-only (no action) — it signals that Shift+drag multi-salvages.
    // Outlined via the programmatic sprite-silhouette highlight while Shift
    // is held so the player sees the mode is active.
    const lightest = active_theme.lightest;
    const salvage_tool_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];
    try elements.append(allocator, .{ .image = .{
        .sprite_id = "ui/salvage_tool",
        .screen_position = .{ .x = sidebar_x, .y = grid_top },
        .width = inventory_slot_size,
        .height = inventory_slot_size,
        .color = salvage_tool_color,
        .highlighted = held_modifiers.shift,
        .tooltip = .{ .header = try spanRow(allocator, text(
            "Hold Shift to salvage items into materials - hold and drag to multi-salvage",
        )) },
        .blocks_input = false,
    } });

    // Shift-drag region outline: a lightest stroked rectangle around the
    // bounding box of the two corner slots. Drawn over the grid (non-blocking)
    // so hover/click still reach the slots beneath.
    if (salvage_region) |region| {
        const start_row = @divTrunc(@as(i32, @intCast(region.start_slot)), types.inventory_columns);
        const start_col = @rem(@as(i32, @intCast(region.start_slot)), types.inventory_columns);
        const end_row = @divTrunc(@as(i32, @intCast(region.end_slot)), types.inventory_columns);
        const end_col = @rem(@as(i32, @intCast(region.end_slot)), types.inventory_columns);
        const min_row = @min(start_row, end_row);
        const min_col = @min(start_col, end_col);
        const max_row = @max(start_row, end_row);
        const max_col = @max(start_col, end_col);
        const region_origin = ScreenPosition{
            .x = grid.origin.x + min_col * inventory_slot_size,
            .y = grid.origin.y + min_row * inventory_slot_size,
        };
        const region_width = (max_col - min_col + 1) * inventory_slot_size;
        const region_height = (max_row - min_row + 1) * inventory_slot_size;
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = region_origin,
            .width = region_width,
            .height = region_height,
            .color = lightest,
            .filled = false,
            .blocks_input = false,
        } });
    }
}

/// Font size for the gear-panel combat-stat lines.
pub const gear_stat_font_size: i32 = 56;

/// The combat-stat labels shown in the gear panel, in display order. Shared
/// between `gearPanelWidth` (measures the longest line for the panel width)
/// and `buildGearPanel` (renders them). Values are runtime, so width is
/// measured against a max-digit template, not the live value.
const gear_stat_labels = [_][]const u8{
    "Main Hand Damage",
    "Off Hand Damage",
    "Spell Damage",
    "Max Health",
    "Defense",
    "Pickup Radius",
    "Speed",
};

/// Gear panel width, derived from the longest stat line so the stats
/// column (flush against the gear stack) fits without truncation.
/// Mirrors the tooltip/error-popup approach (`measureSpanWidth` → content
/// width + padding). Layout: weapon row (2 slots + gap) on top; gear stack
/// (1 slot) under main-hand; stats flush against the gear stack's right
/// edge, starting under the off-hand. Width = margin + slot + stats +
/// margin.
pub fn gearPanelWidth(font_metrics: FontMetrics) i32 {
    // Value gutter: space + up to 2 digits (stats are bounded; see balance
    // bounds in loaders.zig). Keeps the width stable as values change.
    const value_gutter = font_metrics.measureSpanWidth(text(" 99"), gear_stat_font_size);
    var stats_width: i32 = 0;
    for (gear_stat_labels) |label| {
        const line_width = font_metrics.measureSpanWidth(text(label), gear_stat_font_size) + value_gutter;
        if (line_width > stats_width) stats_width = line_width;
    }
    // Non-weapon row content: panel margin (ui_gap) + 1 slot.
    const non_weapon_row_width = ui_gap + inventory_slot_size;
    // Stats content: stats text + panel margin (ui_gap).
    const stats_column_width = stats_width + ui_gap;
    return non_weapon_row_width + stats_column_width;
}

/// Gear panel: equipped weapons (main/off hand) top-left, then amulet →
/// coat → gloves → pants → boots stacked below the main-hand, and combat
/// stats flush against the gear stack's right edge (starting under the
/// off-hand). All slots + item icons 128×128 (`inventory_slot_size`).
/// Panel width is derived from the longest stat line (`gearPanelWidth`);
/// height shares `middle_panel_height` with the other middle panels.
/// Slots carry `ref = .{ .gear = ... }` so drag to/from inventory works
/// (equip/unequip via the existing orchestrator mapping). The item icon is
/// suppressed on the drag source (shown only as the ghost).
pub fn buildGearPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    player: Entity,
    learned_skills: []const types.SkillId,
    active_theme: types.ActiveColorTheme,
    drag_source: ?SlotRef,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Gear", .toggle_gear);

    const p = active_theme.player_gradient.colors;
    const slot_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const cell_size = inventory_slot_size;

    // Emit one gear slot: frame + item icon (suppressed on drag source) +
    // tooltip. The frame carries the ref (drag source + drop target).
    const emitGearSlot = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            cell_pos: ScreenPosition,
            gear_slot: GearSlot,
            pl: Entity,
            skills: []const types.SkillId,
            s_color: Color,
            i_color: Color,
            src: ?SlotRef,
        ) !void {
            const ref: SlotRef = .{ .gear = gear_slot };
            const is_drag_source = if (src) |s| s.eql(ref) else false;
            const item = gearSlotItem(pl, gear_slot);
            // Equipped-item tooltips show no comparisons (an item
            // compared to itself is all zeros).
            const slot_tooltip: ?Tooltip = if (item) |it|
                try buildItemTooltip(alloc, it, skills, null)
            else
                null;
            try elems.append(alloc, .{ .slot = .{
                .screen_position = cell_pos,
                .size = cell_size,
                .icon_sprite_id = "ui/item_slot",
                .icon_color = s_color,
                .ref = ref,
                .tooltip = slot_tooltip,
            } });
            // Item icon on top, suppressed on the drag source ("in flight").
            if (!is_drag_source) {
                if (item) |it| {
                    try elems.append(alloc, .{ .image = .{
                        .sprite_id = itemIconSpriteId(it),
                        .screen_position = cell_pos,
                        .width = cell_size,
                        .height = cell_size,
                        .color = i_color,
                        .blocks_input = false,
                    } });
                }
            }
        }
    }.run;

    // Weapons: main_hand + off_hand side by side on the top row.
    const top_y = origin.y + ui_gap;
    const col0_x = origin.x + ui_gap;
    const col1_x = col0_x + cell_size + ui_gap;
    try emitGearSlot(elements, allocator, .{ .x = col0_x, .y = top_y }, .main_hand, player, learned_skills, slot_color, item_color, drag_source);
    try emitGearSlot(elements, allocator, .{ .x = col1_x, .y = top_y }, .off_hand, player, learned_skills, slot_color, item_color, drag_source);

    // Gear stack: amulet → coat → gloves → pants → boots, each one row below
    // the weapons, under the main-hand column.
    const gear_slots = [_]GearSlot{ .amulet, .coat, .gloves, .pants, .boots };
    var row_y = top_y + cell_size + ui_gap;
    for (gear_slots) |gs| {
        try emitGearSlot(elements, allocator, .{ .x = col0_x, .y = row_y }, gs, player, learned_skills, slot_color, item_color, drag_source);
        row_y += cell_size + ui_gap;
    }

    // Combat stats flush against the gear stack's right edge (no gap),
    // flowing down under the off-hand. Effective values (gear + effect
    // modifiers + momentum where applicable). See `getEffective*` on Entity.
    const stats_x = col0_x + cell_size;
    const stats_top = top_y + cell_size + ui_gap;
    const stat_line_height: i32 = gear_stat_font_size + 16;

    const main_damage = if (player.main_hand_weapon) |w| player.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const off_damage = if (player.off_hand_weapon) |w| player.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const stat_values = [_]u32{
        main_damage,
        off_damage,
        player.getEffectiveSpellDamage(),
        player.getEffectiveMaxHealth(),
        player.getEffectiveDefense(),
        player.getEffectivePickupRadius(0),
        player.getEffectiveSpeed(),
    };

    var stat_y = stats_top;
    for (gear_stat_labels, stat_values) |label, value| {
        const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ label, value });
        try elements.append(allocator, .{ .text_label = .{
            .text = line,
            .screen_position = .{ .x = stats_x, .y = stat_y },
            .font_size = gear_stat_font_size,
            .blocks_input = false,
        } });
        stat_y += stat_line_height;
    }
    _ = font_metrics;
}

/// Entity-inspect panel (right-click an entity in a level). Read-only
/// mirror of the player's skill bar + active effects + gear panel, tinted
/// with the inspected entity's TEAM gradient (player gradient for team 0,
/// enemy gradient otherwise). No slots carry a `SlotRef` and no buttons
/// carry an `Action` — nothing is draggable or clickable; tooltips still
/// work on hover. Opened by right-clicking a tile with an entity (see
/// `handleRightClickInspect` in input_handlers). See DESIGN → UI Framework
/// → Entity inspect.
///
/// Layout (top to bottom inside the panel):
///   1. Skill bar — 4×2 grid of `slot_size` (256) slots, slots 1-4 top row,
///      5-8 bottom. Empty slots show the diamond marker; cooldowns show
///      the translucent wash + remaining-turns number.
///   2. Active effects — `small_icon_size` (128) icons flowing left→right
///      then wrapping down, max 8 columns. Omitted entirely when the entity
///      has no active effects.
///   3. Gear mirror — weapons (main/off hand) top-left, amulet→coat→gloves→
///      pants→boots stacked below the main-hand, combat-stat column flush
///      against the gear stack's right edge (under the off-hand). All 128×128 (`inventory_slot_size`).
pub fn buildEntityInspectPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    entity: Entity,
    learned_skills: []const types.SkillId,
    /// The PLAYER's equipped gear — baseline for the inspected entity's
    /// gear-tooltip comparisons (dropped enemy gear is directly usable,
    /// so the comparison is actionable). Null (inspecting the player
    /// itself, or no player) suppresses comparisons.
    equipped: ?EquippedGear,
    active_theme: types.ActiveColorTheme,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, entity.name, .toggle_entity_inspect);

    // Team gradient: player (team 0) vs enemy (team ≠ 0). Same fixed
    // indices the bottom bar + gear panel use, resolved against the team's
    // own gradient instead of always the player's.
    const g = if (entity.team == 0) active_theme.player_gradient.colors else active_theme.enemy_gradient.colors;
    const c_skill_frame = g[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const c_skill_icon = g[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const c_gear_slot = g[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_gear_item = g[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const cooldown_overlay_color = active_theme.darkest;

    const origin = content.position();

    // --- Skill bar: 4×2 grid of slot_size slots ---
    const skill_grid_origin: ScreenPosition = .{
        .x = origin.x + ui_gap,
        .y = origin.y + ui_gap,
    };
    const skill_grid = Grid{
        .origin = skill_grid_origin,
        .cell_width = slot_size,
        .cell_height = slot_size,
        .gap = 0,
        .columns = 4,
    };
    const skill_slots = entity.collectSkillSlots(weapon_type_definitions);
    for (skill_slots, 0..) |maybe_skill, index| {
        const cell = skill_grid.cell(@intCast(index));
        if (maybe_skill) |skill_id| {
            const definition = lookups.getSkillDefinition(skill_id) orelse {
                // Unknown skill id — render the empty marker rather than crash.
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = "ui/skill_slot_empty",
                    .screen_position = cell.position(),
                    .width = cell.width,
                    .height = cell.height,
                    .color = c_skill_frame,
                } });
                continue;
            };
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "ui/skill_button",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_frame,
                .tooltip = try buildSkillTooltip(allocator, definition),
            } });
            try elements.append(allocator, .{ .image = .{
                .sprite_id = skillIconSpriteId(skill_id),
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_icon,
                .blocks_input = false,
            } });
            const cooldown = entity.skill_cooldowns.get(skill_id);
            if (cooldown > 0) {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = "ui/skill_button",
                    .screen_position = cell.position(),
                    .width = cell.width,
                    .height = cell.height,
                    .color = cooldown_overlay_color,
                    .alpha = 128,
                    .blocks_input = false,
                } });
                try emitCenteredNumber(elements, allocator, font_metrics, cell, cooldown, cooldown_font_size);
            }
        } else {
            // Empty slot — diamond marker, same as the skill bar.
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "ui/skill_slot_empty",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_frame,
            } });
        }
    }

    // --- Active effects: 128px icons, max 8 columns, left→right then down ---
    var cursor_y = skill_grid_origin.y + 2 * slot_size + ui_gap;
    if (entity.active_effects.len > 0) {
        const effects_origin: ScreenPosition = .{
            .x = origin.x + ui_gap,
            .y = cursor_y,
        };
        const effect_columns: i32 = 8;
        for (entity.active_effects, 0..) |effect, index| {
            const ordinal: i32 = @intCast(index);
            const column = @mod(ordinal, effect_columns);
            const grid_row = @divFloor(ordinal, effect_columns);
            const cell: Rectangle = .{
                .x = effects_origin.x + column * small_icon_size,
                .y = effects_origin.y + grid_row * small_icon_size,
                .width = small_icon_size,
                .height = small_icon_size,
            };
            const definition = lookups.getEffectDefinition(effect.effect_id);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = effectIconSpriteId(effect.effect_id, definition),
                .screen_position = cell.position(),
                .width = small_icon_size,
                .height = small_icon_size,
                .color = c_skill_icon,
                .tooltip = .{
                    .header = try spanRow(allocator, text(definition.name)),
                    .body = try allocator.dupe(TooltipRow, &.{
                        try spanRow(allocator, text(definition.description)),
                        try spanRow(allocator, text(
                            try std.fmt.allocPrint(allocator, "Current duration {d}", .{effect.duration}),
                        )),
                    }),
                },
            } });
            try emitCornerNumber(elements, allocator, font_metrics, cell, effect.duration);
        }
        const effect_rows = @divTrunc(@as(i32, @intCast(entity.active_effects.len)) + effect_columns - 1, effect_columns);
        cursor_y += effect_rows * small_icon_size + ui_gap;
    }

    // --- Gear mirror: weapons row + gear stack + stat column ---
    const gear_top_y = cursor_y;
    const gear_cell_size = inventory_slot_size;
    const col0_x = origin.x + ui_gap;
    const col1_x = col0_x + gear_cell_size + ui_gap;

    const emitGearSlot = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            cell_pos: ScreenPosition,
            gear_slot: GearSlot,
            ent: Entity,
            skills: []const types.SkillId,
            item_equipped: ?EquippedGear,
            s_color: Color,
            i_color: Color,
        ) !void {
            const item = gearSlotItem(ent, gear_slot);
            const slot_tooltip: ?Tooltip = if (item) |it|
                try buildItemTooltip(alloc, it, skills, item_equipped)
            else
                null;
            try elems.append(alloc, .{ .image = .{
                .sprite_id = "ui/item_slot",
                .screen_position = cell_pos,
                .width = gear_cell_size,
                .height = gear_cell_size,
                .color = s_color,
                .tooltip = slot_tooltip,
            } });
            if (item) |it| {
                try elems.append(alloc, .{ .image = .{
                    .sprite_id = itemIconSpriteId(it),
                    .screen_position = cell_pos,
                    .width = gear_cell_size,
                    .height = gear_cell_size,
                    .color = i_color,
                    .blocks_input = false,
                } });
            }
        }
    }.run;

    try emitGearSlot(elements, allocator, .{ .x = col0_x, .y = gear_top_y }, .main_hand, entity, learned_skills, equipped, c_gear_slot, c_gear_item);
    try emitGearSlot(elements, allocator, .{ .x = col1_x, .y = gear_top_y }, .off_hand, entity, learned_skills, equipped, c_gear_slot, c_gear_item);

    const gear_slots = [_]GearSlot{ .amulet, .coat, .gloves, .pants, .boots };
    var row_y = gear_top_y + gear_cell_size + ui_gap;
    for (gear_slots) |gs| {
        try emitGearSlot(elements, allocator, .{ .x = col0_x, .y = row_y }, gs, entity, learned_skills, equipped, c_gear_slot, c_gear_item);
        row_y += gear_cell_size + ui_gap;
    }

    // Combat-stat column (flush against the gear stack, same as
    // buildGearPanel).
    const stats_x = col0_x + gear_cell_size;
    const stats_top = gear_top_y + gear_cell_size + ui_gap;
    const stat_line_height: i32 = gear_stat_font_size + 16;
    // The inspect stat column leads with the entity's live combat state
    // (current health, aggro range) before the effective gear stats — the
    // player gear panel shares only the gear-stat tail.
    const entity_stat_labels = [_][]const u8{ "Current Health", "Aggro Range" } ++ gear_stat_labels;
    const main_damage = if (entity.main_hand_weapon) |w| entity.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const off_damage = if (entity.off_hand_weapon) |w| entity.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const stat_values = [_]u32{
        entity.current_health,
        entity.aggro_range,
        main_damage,
        off_damage,
        entity.getEffectiveSpellDamage(),
        entity.getEffectiveMaxHealth(),
        entity.getEffectiveDefense(),
        entity.getEffectivePickupRadius(0),
        entity.getEffectiveSpeed(),
    };
    var stat_y = stats_top;
    for (entity_stat_labels, stat_values) |label, value| {
        const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ label, value });
        try elements.append(allocator, .{ .text_label = .{
            .text = line,
            .screen_position = .{ .x = stats_x, .y = stat_y },
            .font_size = gear_stat_font_size,
            .blocks_input = false,
        } });
        stat_y += stat_line_height;
    }
}

/// Skills browser panel: a 9-slice background, then a 4-wide grid of
/// `slot_size` (256) skill slots filling downward from the top-left, one
/// per learned skill in `learned_skills` order (parsed order — no
/// sorting/grouping/search yet). Each slot is a `ui/skill_button` frame
/// tinted with player-gradient index 3 carrying `ref = .{ .learned_skill =
/// ... }` (drag source/drop target) + a non-blocking `skills/<tag>` icon
/// overlay tinted with index 1, mirroring the skill bar. No `action` —
/// clicking a browser entry doesn't fire a skill (it's not on the bar);
/// drag-to-bar is not wired (see TODO → UI Framework). The drag source's
/// icon is suppressed ("in flight"), matching inventory/gear.
///
/// Vertical overflow is cut at a full skill's bottom (no half-skills): only
/// whole rows within the visible height are emitted. A scrollbar (track +
/// proportional thumb) sits in the right `ui_gap` margin when the skill
/// count exceeds the visible rows. `scroll_offset` (in rows) is clamped to
/// `[0, max_scroll_row]` here — the authoritative clamp, since only the
/// view knows `max_scroll_row`.
pub fn buildSkillsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    learned_skills: []const SkillId,
    active_theme: types.ActiveColorTheme,
    /// In/out: current scroll offset in rows; clamped here to `[0, max_scroll_row]`.
    scroll_offset: *i32,
    /// The slot currently being dragged from, if any. The skill icon is
    /// suppressed on the source slot so it reads as "in flight" (shown only
    /// as the drag ghost). The frame + ref still emit so the slot stays a
    /// drop target.
    drag_source: ?SlotRef,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Skills", .toggle_skills);

    const p = active_theme.player_gradient.colors;
    const frame_color = p[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const icon_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const grid_origin: ScreenPosition = .{
        .x = origin.x + ui_gap,
        .y = origin.y + ui_gap,
    };
    const grid_height = content.height - 2 * ui_gap;
    const visible_rows = @divFloor(grid_height, slot_size);
    const total_rows = @divTrunc(@as(i32, @intCast(learned_skills.len)) + skills_panel_columns - 1, skills_panel_columns);
    const max_scroll_row = @max(@as(i32, 0), total_rows - visible_rows);
    // Authoritative clamp (the input handler can't know max_scroll_row).
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;
    const first_row = scroll_offset.*;

    const grid = Grid{
        .origin = grid_origin,
        .cell_width = slot_size,
        .cell_height = slot_size,
        .gap = 0,
        .columns = skills_panel_columns,
    };

    // Emit only the fully-visible rows, drawn at the TOP of the grid region
    // (view-relative positions — the scrollbar thumb conveys the scroll
    // position, same pattern as `buildErrorPopup`'s body window). A row that
    // wouldn't fully fit is not emitted (no half-skills).
    const visible_row_count = @min(visible_rows, @max(@as(i32, 0), total_rows - first_row));
    var view_row: i32 = 0;
    while (view_row < visible_row_count) : (view_row += 1) {
        var column: i32 = 0;
        while (column < skills_panel_columns) : (column += 1) {
            const index: usize = @intCast((first_row + view_row) * skills_panel_columns + column);
            if (index >= learned_skills.len) break;
            const skill_id = learned_skills[index];
            const cell = grid.cell(view_row * skills_panel_columns + column);
            const ref: SlotRef = .{ .learned_skill = skill_id };
            const is_drag_source = if (drag_source) |src| src.eql(ref) else false;
            // Drag source: render the empty-slot diamond so the skill reads
            // as "in flight" (shown only as the drag ghost following the
            // pointer). The frame keeps its ref so the slot stays a drop
            // target for a same-slot drop (a no-op). Mirrors `emitSkillButton`'s
            // drag-source / empty handling. No tooltip — globally suppressed
            // while a drag is active anyway (see view.zig).
            if (is_drag_source) {
                try elements.append(allocator, .{ .slot = .{
                    .screen_position = cell.position(),
                    .size = slot_size,
                    .icon_sprite_id = "ui/skill_slot_empty",
                    .icon_color = frame_color,
                    .ref = ref,
                } });
                continue;
            }
            const definition = lookups.getSkillDefinition(skill_id);
            const slot_tooltip: ?Tooltip = if (definition) |def|
                try buildSkillTooltip(allocator, def)
            else
                null;
            // Frame carries the slot identity (drag source + drop target).
            try elements.append(allocator, .{ .slot = .{
                .screen_position = cell.position(),
                .size = slot_size,
                .icon_sprite_id = "ui/skill_button",
                .icon_color = frame_color,
                .ref = ref,
                .tooltip = slot_tooltip,
            } });
            // Skill icon on top.
            {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = skillIconSpriteId(skill_id),
                    .screen_position = cell.position(),
                    .width = slot_size,
                    .height = slot_size,
                    .color = icon_color,
                    .blocks_input = false,
                } });
            }
        }
    }

    // Scrollbar (only when the skill count overflows the visible rows). Track
    // + proportional thumb in the right `ui_gap` margin, spanning the grid's
    // height. Mirrors `buildErrorPopup`'s scrollbar geometry.
    if (total_rows > visible_rows) {
        const track_x = origin.x + bounds.width - ui_gap +
            @divFloor(ui_gap - skills_scrollbar_width, 2);
        const track_y = grid_origin.y;
        const track_height = visible_rows * slot_size;
        const track_color: types.Color = .{ .r = 80, .g = 80, .b = 80 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = track_y },
            .width = skills_scrollbar_width,
            .height = track_height,
            .color = track_color,
        } });
        const thumb_height = @max(
            @as(i32, 40),
            @divTrunc(track_height * visible_rows, total_rows),
        );
        const thumb_y = track_y +
            @divTrunc(scroll_offset.* * (track_height - thumb_height), max_scroll_row);
        const thumb_color: types.Color = .{ .r = 180, .g = 180, .b = 180 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = thumb_y },
            .width = skills_scrollbar_width,
            .height = thumb_height,
            .color = thumb_color,
        } });
    }

    _ = font_metrics;
}

test "buildSkillsPanel: few skills — one row, slots + icons, no scrollbar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const learned = [_]SkillId{ .slice, .stab, .chop };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 5; // clamped to 0 (no overflow)

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(&elements, arena.allocator(), metrics, bounds, &learned, theme, &scroll_offset, null);

    // 1 panel + 2 header (title + close button) + 3 slots + 3 icons, no scrollbar.
    try std.testing.expectEqual(@as(usize, 9), elements.items.len);
    try std.testing.expectEqual(@as(i32, 0), scroll_offset); // clamped
    for (elements.items) |element| switch (element) {
        .solid_rect => @panic("unexpected scrollbar for few skills"),
        else => {},
    };
}

test "buildSkillsPanel: overflow — scrollbar present, only visible rows emitted, no half-skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 25 skills → 7 rows (ceil(25/4)); visible_rows = 6 (1536/256). Overflow
    // by 1 row → max_scroll_row = 1.
    const learned = [_]SkillId{
        .slice, .stab, .chop, .cleave,
        .slam, .skewer, .impale, .bash,
        .blink, .blitz, .daze, .focus,
        .howl, .reflect, .replenish, .retreating_swipe,
        .spark, .spinblade, .stone_form, .swap,
        .that_which_lingers, .throw, .toss, .vampiric_strike,
        .flash_strike,
    };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 100; // clamped to max_scroll_row = 1

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(&elements, arena.allocator(), metrics, bounds, &learned, theme, &scroll_offset, null);

    // scroll clamped to the last row.
    try std.testing.expectEqual(@as(i32, 1), scroll_offset);

    // Count slots: only the fully-visible rows emit. At scroll_offset = 1,
    // visible rows are [1, 7) = 6 rows = 24 cells, but row 6 has only 1 skill
    // (25 - 24 = 1), so 24 - 3 = 21 slots. Each slot has an icon → 21 icons.
    var slot_count: usize = 0;
    var icon_count: usize = 0;
    var solid_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .slot => slot_count += 1,
        .image => icon_count += 1,
        .solid_rect => solid_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 21), slot_count);
    try std.testing.expectEqual(@as(usize, 21), icon_count);
    // Scrollbar: track + thumb.
    try std.testing.expectEqual(@as(usize, 2), solid_count);

    // No slot's bottom edge exceeds the visible grid bottom (no half-skills).
    const grid_top = middle_panel_header_height + ui_gap;
    const grid_bottom = grid_top + 6 * slot_size; // visible_rows * slot_size
    for (elements.items) |element| switch (element) {
        .slot => |slot| {
            const bottom = slot.screen_position.y + slot.size;
            try std.testing.expect(bottom <= grid_bottom);
        },
        else => {},
    };
}

test "buildSkillsPanel: drag source suppresses the icon, keeps the slot ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const learned = [_]SkillId{ .slice, .stab };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 0;
    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(
        &elements,
        arena.allocator(),
        metrics,
        bounds,
        &learned,
        theme,
        &scroll_offset,
        SlotRef{ .learned_skill = .slice }, // dragging the first skill
    );

    // The first slot keeps its ref (drop target) and renders the empty-slot
    // diamond ("in flight"); the second emits the skill_button frame + icon.
    var found_source_slot = false;
    var found_source_diamond = false;
    var image_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .slot => |slot| if (slot.ref != null and slot.ref.?.eql(.{ .learned_skill = .slice })) {
            found_source_slot = true;
            found_source_diamond = std.mem.eql(u8, slot.icon_sprite_id orelse "", "ui/skill_slot_empty");
        },
        .image => image_count += 1,
        else => {},
    };
    try std.testing.expect(found_source_slot);
    try std.testing.expect(found_source_diamond);
    // Only the second skill's icon emits; the drag source's is suppressed.
    try std.testing.expectEqual(@as(usize, 1), image_count);
}

/// Top bar: options button flush in the top-left corner, then `ui_gap`,
/// then the undo button, then the remaining width reserved for the combat
/// log (not rendered — see TODO → Combat Log). Left-anchored row mirroring
/// the bottom bar's conventions (`Row`, `ui_gap`, `slot_size`). No
/// background of its own — purely a layout region, like the bottom bar.
/// Undo is never disabled: the
/// only state with nothing to undo is a fresh main menu, where this bar is
/// not shown; `history.undo` no-ops at the earliest idle point regardless.
pub fn buildTopBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    screen: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    // Match the bottom-bar skip button: background = gradient[5], icon = gradient[1].
    const c_btn_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_btn_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    var row = Row.init(screen.position(), top_bar_height, ui_gap);

    // Options button — flush in the top-left corner (no margin). Layered
    // background + icon, same as the skip button.
    const options_cell = row.next(slot_size);
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

    // Undo button — same size, one `ui_gap` to the right of options. Same
    // layered background + icon treatment as the options button.
    const undo_cell = row.next(slot_size);
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
}

/// Build the mission-complete overlay: a full-screen 9-slice panel with a
/// "{mission_name} completed" header centered at the top, a centered "New
/// clone: [icons]" summary line below it, a two-column area (left stats,
/// right clone-harvest rewards with its own sub-header) extending downward,
/// and Continue + Replay Mission (+ Overwrite Clone if offered) buttons side
/// by side at the bottom. Rendered when `GameState.last_completed_mission`
/// is set (the player completed the last level of a mission; the cascade has
/// already transitioned to the hub). See DESIGN → Architecture + DESIGN →
/// Clones (clone system).
pub fn buildMissionComplete(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    info: types.MissionCompleteInfo,
    active_theme: types.ActiveColorTheme,
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

    // ── Header: "{name} completed", centered at the top. ──
    const header_font_size: i32 = 128;
    const header_text = try std.fmt.allocPrint(allocator, "{s} completed", .{info.name});
    const header_width = font_metrics.measureSpanWidth(text(header_text), header_font_size);
    const header_box = screen.placeTopCenter(header_width, header_font_size, ui_gap * 4);
    try elements.append(allocator, .{ .text_label = .{
        .text = header_text,
        .screen_position = header_box.position(),
        .font_size = header_font_size,
        .blocks_input = false,
    } });

    // ── "New clone: [horizontal icons]" — centered below the header. ──
    // Shows the just-completed run's converted_materials (the clone's
    // rate numerator). The icon row is horizontal + compact (96px icons)
    // so the whole line reads as one summary.
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

    // ── Two columns extending down from below the new-clone line. ──
    const content_y = new_clone_y + new_clone_icon_size + ui_gap * 4;

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

    // Right column: "Clone material harvest" sub-header + vertical material
    // icon stack (flush right, top-aligned at content_y).
    const harvest_header_font_size: i32 = 64;
    const harvest_header_text = "Clone material harvest";
    const harvest_header_width = font_metrics.measureSpanWidth(text(harvest_header_text), harvest_header_font_size);
    const material_right = screen.x + screen.width - ui_gap * 4;
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

    // ── Bottom buttons: Replay Mission in the bottom-left corner, Continue
    //    in the bottom-right corner. Overwrite Clone (when offered) sits
    //    centered between them. ──
    const buttons_row = screen.placeBottomCenter(menu_button_width, panel_button_height, ui_gap * 4);
    const button_y = buttons_row.y;
    const margin = ui_gap * 4;
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
    save_files: []const @import("file_source.zig").SaveFileEntry,
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
    local_missions: []const @import("file_source.zig").FileSource.MissionEntry,
    official_missions: []const @import("file_source.zig").FileSource.MissionEntry,
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

    // Build a message long enough to overflow error_popup_max_body_height.
    // Each line is ~56px; 1600px / 56 ≈ 28 lines fit. Generate 60 lines.
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(std.testing.allocator);
    for (0..60) |i| {
        if (i > 0) msg.appendSlice(std.testing.allocator, "\n") catch @panic("msg");
        msg.appendSlice(std.testing.allocator, "This is warning line number X with some text.") catch @panic("msg");
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

test "buildErrorPopup: scroll offset clamped to max_scroll on long message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};
    session.error_scroll_offset = 100_000; // way past max_scroll

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(std.testing.allocator);
    for (0..60) |i| {
        if (i > 0) msg.appendSlice(std.testing.allocator, "\n") catch @panic("msg");
        msg.appendSlice(std.testing.allocator, "This is warning line number X with some text.") catch @panic("msg");
    }

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, msg.items, .{ .r = 50, .g = 50, .b = 50 });

    // Clamped to max_scroll (which is body_content_height - visible_body_height,
    // both positive since content overflows). Exact value depends on wrapping,
    // but it must be > 0 and < the original 100_000.
    try std.testing.expect(session.error_scroll_offset > 0);
    try std.testing.expect(session.error_scroll_offset < 100_000);
}

fn testWeaponTypeDefinitions() [weapon_type_count]WeaponTypeDefinition {
    var defs: [weapon_type_count]WeaponTypeDefinition = undefined;
    for (&defs) |*d| d.* = .{ .skill_1 = .stab, .skill_2 = .chop, .skill_3 = .throw };
    return defs;
}

test "buildEntityInspectPanel: player entity emits skill + gear slots, read-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const player_color: types.Color = .{ .r = 10, .g = 20, .b = 30 };
    const enemy_color: types.Color = .{ .r = 90, .g = 80, .b = 70 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{enemy_color} ** 6 },
        .player_gradient = .{ .colors = .{player_color} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 0;
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    entity.off_hand_weapon = .{ .weapon_type = .shield };
    entity.equipped_utility_skills = .{ .slice, .stab, null, null, null };

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // No .slot elements and no gameplay-clickable .button — everything is
    // read-only .image, except the panel-header close button (a .button
    // carrying the toggle_entity_inspect action).
    for (elements.items) |element| switch (element) {
        .slot => @panic("inspect panel emitted a draggable .slot"),
        .button => |btn| if (btn.action != .toggle_entity_inspect) {
            @panic("inspect panel emitted a clickable .button other than close");
        },
        else => {},
    };

    // The skill-bar frame images are tinted with the PLAYER gradient (team 0).
    const expected_frame = player_color; // index 3 → player_color (all 6 are same)
    var found_skill_frame = false;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button")) {
            try std.testing.expectEqual(expected_frame, img.color);
            found_skill_frame = true;
        },
        else => {},
    };
    try std.testing.expect(found_skill_frame);
}

test "buildEntityInspectPanel: enemy entity uses enemy gradient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const player_color: types.Color = .{ .r = 10, .g = 20, .b = 30 };
    const enemy_color: types.Color = .{ .r = 90, .g = 80, .b = 70 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{enemy_color} ** 6 },
        .player_gradient = .{ .colors = .{player_color} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 1; // enemy
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    entity.current_health = 7;
    entity.aggro_range = 5;

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // Skill-bar frame tinted with the ENEMY gradient (team ≠ 0).
    var found_enemy_frame = false;
    // The stat column LEADS with the entity's live combat state.
    var found_current_health = false;
    var found_aggro_range = false;
    var stat_lines: usize = 0;
    var first_stat_lines: [2][]const u8 = undefined;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button")) {
            try std.testing.expectEqual(enemy_color, img.color);
            found_enemy_frame = true;
        },
        .text_label => |label| {
            // Stat lines live in the column flush against the gear stack
            // (x = 16 + 128); the panel title shares the font size, so gate
            // on position, not just text.
            if (label.screen_position.x == ui_gap + inventory_slot_size and label.font_size == gear_stat_font_size) {
                if (stat_lines < 2) first_stat_lines[stat_lines] = label.text;
                stat_lines += 1;
                if (std.mem.eql(u8, label.text, "Current Health 7")) found_current_health = true;
                if (std.mem.eql(u8, label.text, "Aggro Range 5")) found_aggro_range = true;
            }
        },
        else => {},
    };
    try std.testing.expect(found_enemy_frame);
    try std.testing.expect(found_current_health);
    try std.testing.expect(found_aggro_range);
    // The two live-state rows lead the column (before the gear stats).
    try std.testing.expect(stat_lines == 9);
    try std.testing.expectEqualStrings("Current Health 7", first_stat_lines[0]);
    try std.testing.expectEqualStrings("Aggro Range 5", first_stat_lines[1]);
}

test "buildEntityInspectPanel: cooldown overlay + number when skill on cooldown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 0;
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    // Slot 1 = stab (sword skill_1); put it on cooldown.
    entity.skill_cooldowns.set(.stab, 3);

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // A cooldown overlay is a translucent (alpha 128) skill_button image on
    // top of the filled slot. Count them — exactly one skill is on cooldown.
    var overlay_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button") and img.alpha == 128) {
            overlay_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), overlay_count);
}

test "buildEntityInspectPanel: active effects emit 128px icons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 1;
    // Allocate active_effects in the arena (Entity.active_effects is a slice).
    const effects = try arena.allocator().alloc(types.Effect, 2);
    effects[0] = .{ .effect_id = .reflect, .duration = 2 };
    effects[1] = .{ .effect_id = .stone_form, .duration = 4 };
    entity.active_effects = effects;

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // Two effect icons at 128px, carrying tooltips.
    var effect_icon_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .image => |img| if (img.width == small_icon_size and img.height == small_icon_size and img.tooltip != null) {
            // Effect icons use the effect definition name as the sprite id.
            // Effect icons use the SKILL icon (`skills/<tag>`) when the
            // effect shares a tag with a skill (reflect/stone_form do).
            if (std.mem.eql(u8, img.sprite_id, "skills/reflect") or std.mem.eql(u8, img.sprite_id, "skills/stone_form")) {
                effect_icon_count += 1;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), effect_icon_count);
}

test "buildLoadSavePanel: rows carry refs + actions, scroll window + clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    // Enough rows to overflow the visible window (rows region is roughly
    // 2160 - 2*48 - header(~86) - 32 - 160 - 48 ≈ 1700px → ~14 visible rows).
    var files: [20]@import("file_source.zig").SaveFileEntry = undefined;
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
    const MissionEntry = @import("file_source.zig").FileSource.MissionEntry;

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

test "buildEditorSkillPicker: header + close + None + one cell per utility skill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, .{ .r = 30, .g = 30, .b = 30 }, black, black, black, .{ .r = 40, .g = 40, .b = 40 } } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // Slot 1 (Slot 5) already carries blink — its cell is highlighted,
    // the None cell is not.
    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton", .template = .{
        .equipped_utility_skills = .{ null, .blink, null, null, null },
    } }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    var elements: UiElementList = .empty;
    try buildEditorSkillPicker(&elements, arena.allocator(), metrics, editor, .{ .utility_skill_slot = 1 }, theme);

    // The panel is the FIXED picker overlay — the band between the
    // sidebars (full sidebar-panel height, a ui_gap in from each).
    const panel = elements.items[0].nine_slice_panel;
    try std.testing.expectEqual(
        editorPickerOverlayRect(),
        Rectangle{
            .x = panel.screen_position.x,
            .y = panel.screen_position.y,
            .width = panel.width,
            .height = panel.height,
        },
    );
    try std.testing.expectEqual(@as(i32, 1760), editorPickerOverlayRect().width);
    try std.testing.expectEqual(@as(i32, 1328), editorPickerOverlayRect().height);

    // Panel + header label + close + None (button + label) + 7 ×
    // (button + full-size icon) = 19 — real skills are icon-only.
    try std.testing.expectEqual(@as(usize, 19), elements.items.len);

    var picker_buttons: usize = 0;
    var highlighted_skill: ?types.SkillId = null;
    var none_highlighted = false;
    var saw_blink_cell = false;
    var saw_header = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_utility_skill) {
            picker_buttons += 1;
            if (button.editor_skill == null) {
                none_highlighted = button.highlighted;
            } else if (button.highlighted) {
                highlighted_skill = button.editor_skill;
            }
            if (button.editor_skill == .blink) saw_blink_cell = true;
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Assign Slot 5")) saw_header = true;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 8), picker_buttons); // None + 7 skills
    try std.testing.expectEqual(types.SkillId.blink, highlighted_skill.?);
    try std.testing.expect(!none_highlighted);
    try std.testing.expect(saw_blink_cell);
    try std.testing.expect(saw_header);
    // No weapon-skill payload anywhere.
    for (elements.items) |element| switch (element) {
        .button => |button| try std.testing.expect(
            button.editor_skill == null or utility_skills.isUtilitySkill(button.editor_skill.?),
        ),
        else => {},
    };

    // The PLAYER fallback target: the picker reads the player loadout's
    // slots (the '!' selected under the select tool resolves to the
    // player).
    {
        const player_editor: types.Editor = .{
            .player_def = .{ .id = "Player", .template = .{
                .equipped_utility_skills = .{ null, .stone_form, null, null, null },
            } },
            .active_tool = .select,
            .selection = &.{.{ .player_start = {} }},
        };
        var player_elements: UiElementList = .empty;
        try buildEditorSkillPicker(
            &player_elements,
            arena.allocator(),
            metrics,
            player_editor,
            .{ .utility_skill_slot = 1 },
            theme,
        );
        var player_highlighted: ?types.SkillId = null;
        for (player_elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_utility_skill and
                button.highlighted and button.editor_skill != null)
            {
                player_highlighted = button.editor_skill;
            },
            else => {},
        };
        try std.testing.expectEqual(types.SkillId.stone_form, player_highlighted.?);
    }
}

test "buildEditorSpritePicker: tabs, official cells (player excluded), mission-local namespaced cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Bear",
        .template = .{ .name = "Bear", .sprite = "bear", .team = 1 },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    };

    // Official tab: one cell per shipped enemy sprite, the player body
    // excluded; the current sprite (bear) highlighted; every cell carries
    // its stem payload + the shipped sprite graphic.
    {
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(&elements, arena.allocator(), metrics, editor, theme, &.{}, &.{}, .entity_sprite, .official);
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_player = false;
        var saw_bear_graphic = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_sprite) {
                pick_buttons += 1;
                if (std.mem.eql(u8, button.editor_sprite.?, "player")) saw_player = true;
                if (button.highlighted) highlighted = button.editor_sprite;
            } else if (button.action == .select_editor_sprite_tab) {
                // Tabs: Mission + Official, the active one highlighted.
                if (button.editor_sprite_tab.? == .official) {
                    try std.testing.expect(button.highlighted);
                } else {
                    try std.testing.expect(!button.highlighted);
                }
            },
            .image => |image| if (std.mem.eql(u8, image.sprite_id, "entities/bear")) {
                saw_bear_graphic = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 9), pick_buttons); // 10 shipped minus player
        try std.testing.expect(!saw_player);
        try std.testing.expectEqualStrings("bear", highlighted.?);
        try std.testing.expect(saw_bear_graphic);
    }

    // Mission tab: the scanned file names become namespaced
    // `custom/<mission-dir>/<stem>` payloads, shown as TEXT cells (the art
    // isn't renderable until custom-asset rendering lands).
    {
        const mission_sprites = [_][]const u8{ "boss.png", "minion.png" };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &mission_sprites,
            &.{},
            .entity_sprite,
            .mission_local,
        );
        var payloads: [2][]const u8 = .{ "", "" };
        var pick_buttons: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_sprite) {
                payloads[pick_buttons] = button.editor_sprite.?;
                pick_buttons += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), pick_buttons);
        try std.testing.expectEqualStrings("custom/artists_den/boss", payloads[0]);
        try std.testing.expectEqualStrings("custom/artists_den/minion", payloads[1]);
        // The mission tab's cells carry text labels, no sprite graphics.
        try std.testing.expectEqualStrings("boss", findLabel(&elements, "boss").text);
    }
}

/// Find the first text label with exactly `label_text` (test helper).
fn findLabel(elements: *const UiElementList, label_text: []const u8) TextLabel {
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (std.mem.eql(u8, label.text, label_text)) return label,
        else => {},
    };
    @panic("label not found");
}

test "buildEditorSpritePicker: decoration target — registry official cells, namespaced mission cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const world_four: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{ black, black, black, black, world_four, black } },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const tree_footprint = [_]types.Vector2{.{ .x = 1, .y = 2 }};
    const tree_layers = [_]types.DecorationLayer{.{
        .sprite = "tree_1_canopy",
        .color_index = 2,
        .pixel_dims = .{ .x = 512, .y = 768 },
    }};
    const registry = [_]types.DecorationTypeDef{
        .{
            .id = "tree_1",
            .sprite = "tree_1",
            .footprint = &tree_footprint,
            .pixel_dims = .{ .x = 512, .y = 768 },
            .color_index = 4,
            .layers = &tree_layers,
        },
        .{ .id = "stone_2", .sprite = "stone_2", .pixel_dims = .{ .x = 512, .y = 256 } },
    };
    const stone_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &stone_footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
        .color_index = 4,
    }};
    const editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    };

    // Official tab: one cell per registry prefab — the decoration pick
    // action, the shipped `decorations/<stem>` graphic, the current sprite
    // (stone_2) highlighted, world-gradient tint at the type's color.
    {
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &registry,
            .decoration_sprite,
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_tree_graphic = false;
        var saw_world_tint = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_sprite) {
                pick_buttons += 1;
                if (button.highlighted) highlighted = button.editor_sprite;
            },
            .image => |image| {
                if (std.mem.eql(u8, image.sprite_id, "decorations/tree_1")) saw_tree_graphic = true;
                if (std.meta.eql(image.color, world_four)) saw_world_tint = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), pick_buttons);
        try std.testing.expectEqualStrings("stone_2", highlighted.?);
        try std.testing.expect(saw_tree_graphic);
        try std.testing.expect(saw_world_tint);
    }

    // Mission tab: same namespacing as the entity picker; text cells (the
    // art isn't renderable until custom-asset rendering lands).
    {
        const mission_sprites = [_][]const u8{"banner.png"};
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &mission_sprites,
            &registry,
            .decoration_sprite,
            .mission_local,
        );
        var pick_buttons: usize = 0;
        var payload: ?[]const u8 = null;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_sprite) {
                pick_buttons += 1;
                payload = button.editor_sprite;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), pick_buttons);
        try std.testing.expectEqualStrings("custom/artists_den/banner", payload.?);
    }
}

test "buildEditorSpritePicker: layer modes — entity stems, dims-filtered decoration stems" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // ENTITY layer mode (editing layer 0, sprite "bear"): the Official
    // tab lists the shipped entity sprites (player excluded) with the
    // entity-layer pick action; the edited layer's sprite highlights.
    {
        const entity_layers = [_]types.EntityLayer{.{ .sprite = "bear", .color_index = 2 }};
        const entity_types = [_]types.EntityTypeDef{.{
            .id = "Skeleton",
            .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1, .layers = &entity_layers },
        }};
        const editor: types.Editor = .{
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 0 },
        };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &.{},
            .{ .entity_layer = 0 },
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_player = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_layer) {
                pick_buttons += 1;
                if (std.mem.eql(u8, button.editor_sprite.?, "player")) saw_player = true;
                if (button.highlighted) highlighted = button.editor_sprite;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 9), pick_buttons);
        try std.testing.expect(!saw_player);
        try std.testing.expectEqualStrings("bear", highlighted.?);
    }

    // DECORATION layer mode (add — null index): the Official tab lists
    // ONLY the shipped decoration sprites whose dims match the base
    // type's (512x256 here) — the load-time layer invariant — with the
    // decoration-layer pick action; nothing highlights in add mode.
    {
        const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
        const decoration_types = [_]types.DecorationTypeDef{.{
            .id = "stone_2",
            .sprite = "stone_2",
            .footprint = &footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
        }};
        const editor: types.Editor = .{
            .decoration_types = &decoration_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &.{},
            .{ .decoration_layer = null },
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted_count: usize = 0;
        var saw_mismatched_dims = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_layer) {
                pick_buttons += 1;
                if (button.highlighted) highlighted_count += 1;
            },
            .image => |image| {
                // The cells' graphics all aspect-fit at 512x256 (the
                // entity-frame convention is 512x640 — a mismatched
                // filter leak would show up as a taller fit).
                if (image.height > @divFloor(slot_size * 256, 512)) saw_mismatched_dims = true;
            },
            else => {},
        };
        try std.testing.expect(pick_buttons > 0);
        try std.testing.expectEqual(@as(usize, 0), highlighted_count);
        try std.testing.expect(!saw_mismatched_dims);
    }
}

test "buildEditorFootprintEditor: tile cells, white region outline, confirm; inspector row opens it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
    }};
    const editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
    };

    // The editor panel with the draft selecting ONLY cell (0,0): two
    // toggle cells, the shipped-sprite graphic, a 4-bar white outline
    // around the lone selected cell (every side is a boundary — the
    // neighbor (1,0) is unselected, the others off-grid), and the
    // Confirm button.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        ui_state.editor_footprint_draft[0] = true;
        try buildEditorFootprintEditor(&elements, arena.allocator(), metrics, editor, theme, 0, &ui_state);

        var toggle_buttons: usize = 0;
        var saw_graphic = false;
        var saw_confirm = false;
        var saw_close = false;
        var white_bars: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .toggle_editor_footprint_tile) {
                    toggle_buttons += 1;
                    try std.testing.expect(button.editor_footprint_tile != null);
                }
                if (button.action == .confirm_editor_footprint) saw_confirm = true;
                if (button.action == .close_editor_picker) saw_close = true;
            },
            .image => |image| {
                if (std.mem.eql(u8, image.sprite_id, "decorations/stone_2")) saw_graphic = true;
            },
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, default_tint)) white_bars += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), toggle_buttons);
        try std.testing.expect(saw_graphic);
        try std.testing.expect(saw_confirm);
        try std.testing.expect(saw_close);
        try std.testing.expectEqual(@as(usize, 4), white_bars);
    }

    // A custom-stem type: no renderable art — the cells get dark fills so
    // the grid stays visible (2 fills, no image).
    {
        const custom_types = [_]types.DecorationTypeDef{.{
            .id = "custom/x/banner",
            .sprite = "custom/x/banner",
            .footprint = &footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
        }};
        const custom_editor: types.Editor = .{
            .decoration_types = &custom_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        ui_state.editor_footprint_draft[0] = true;
        ui_state.editor_footprint_draft[1] = true;
        try buildEditorFootprintEditor(&elements, arena.allocator(), metrics, custom_editor, theme, 0, &ui_state);

        var saw_image = false;
        var dark_fills: usize = 0;
        var white_bars: usize = 0;
        for (elements.items) |element| switch (element) {
            .image => saw_image = true,
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, .{ .r = 40, .g = 40, .b = 40 })) dark_fills += 1;
                if (std.meta.eql(rect.color, default_tint)) white_bars += 1;
            },
            else => {},
        };
        try std.testing.expect(!saw_image);
        try std.testing.expectEqual(@as(usize, 2), dark_fills);
        // Both cells selected: the region's boundary is the 2x1 block's
        // outer rectangle — 6 bars (2 top + 2 bottom + 1 left + 1 right).
        try std.testing.expectEqual(@as(usize, 6), white_bars);
    }

    // The inspector's Footprint row: a "<N> tiles" button that opens the
    // editor.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var saw_footprint_button = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .open_editor_footprint_picker) {
                saw_footprint_button = true;
            },
            else => {},
        };
        try std.testing.expect(saw_footprint_button);
    }

    // An oversized sprite SCALES DOWN to fit the fixed overlay: a
    // 4096×256 (16×1-grid) sprite scales to 1728/4096 of 1:1 — the
    // toggle cells shrink to 108px, the fixed overlay unchanged.
    {
        const wide_types = [_]types.DecorationTypeDef{.{
            .id = "wide",
            .sprite = "wide",
            .footprint = &.{.{ .x = 0, .y = 0 }},
            .pixel_dims = .{ .x = 4096, .y = 256 },
        }};
        const wide_editor: types.Editor = .{
            .decoration_types = &wide_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var wide_elements: UiElementList = .empty;
        var wide_ui_state: UiState = .{};
        try buildEditorFootprintEditor(&wide_elements, arena.allocator(), metrics, wide_editor, theme, 0, &wide_ui_state);
        var saw_scaled_cell = false;
        for (wide_elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .toggle_editor_footprint_tile) {
                    try std.testing.expectEqual(@as(i32, 108), button.width);
                    saw_scaled_cell = true;
                }
            },
            else => {},
        };
        try std.testing.expect(saw_scaled_cell);
        const panel = wide_elements.items[0].nine_slice_panel;
        try std.testing.expectEqual(
            editorPickerOverlayRect(),
            Rectangle{
                .x = panel.screen_position.x,
                .y = panel.screen_position.y,
                .width = panel.width,
                .height = panel.height,
            },
        );
    }
}

test "buildEditorThemePicker: one strip per gradient, current row framed, close button" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    var gradients: [3]types.ColorGradient = undefined;
    for (&gradients, 0..) |*gradient, index| {
        const value: u8 = @intCast(index * 40 + 10);
        gradient.* = .{ .colors = .{types.Color{ .r = value, .g = value, .b = value }} ** types.gradient_color_count };
    }
    const definitions: types.ColorThemeDefinitions = .{
        .lightest = lightest,
        .darkest = black,
        .gradients = &gradients,
    };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = gradients[0],
        .enemy_gradient = gradients[1],
        .player_gradient = gradients[2],
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const levels = [_]types.EditorLevel{.{ .color_wheel_index = 2 }};
    const editor: types.Editor = .{ .levels = &levels };

    // World role: the current index is the wheel index (2) — row 2 framed.
    {
        var elements: UiElementList = .empty;
        try buildEditorThemePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            definitions,
            theme,
            .{ .level_index = 0, .role = .world },
        );
        // The FIXED picker overlay + header label + close + 3 rows ×
        // (6 blocks + button) + 4 frame rects on the current row = 28.
        const panel = elements.items[0].nine_slice_panel;
        try std.testing.expectEqual(
            editorPickerOverlayRect(),
            Rectangle{
                .x = panel.screen_position.x,
                .y = panel.screen_position.y,
                .width = panel.width,
                .height = panel.height,
            },
        );
        try std.testing.expectEqual(@as(usize, 28), elements.items.len);
        // The strips are FIXED-SIZE (6 × slot_size wide, slot_size tall),
        // not stretched to the overlay — the row's button spans the whole
        // strip (the 6 blocks beneath it are slot_size/6 each).
        try std.testing.expectEqual(@as(?u32, 0), elements.items[9].button.editor_gradient);
        try std.testing.expectEqual(6 * slot_size, elements.items[9].button.width);
        try std.testing.expectEqual(slot_size, elements.items[9].button.height);
        try std.testing.expectEqual(@as(i32, 256), elements.items[3].solid_rect.width);

        var pick_buttons: usize = 0;
        var current_button: ?Button = null;
        var close_seen = false;
        var frame_rects: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| switch (button.action) {
                .select_editor_level_gradient => {
                    pick_buttons += 1;
                    if (button.highlighted) current_button = button;
                },
                .close_editor_picker => close_seen = true,
                else => {},
            },
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, lightest)) frame_rects += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 3), pick_buttons);
        try std.testing.expect(close_seen);
        try std.testing.expectEqual(@as(usize, 4), frame_rects);
        try std.testing.expect(current_button != null);
        try std.testing.expectEqual(@as(?u32, 2), current_button.?.editor_gradient);
    }

    // Enemy role on auto: the current index is the DERIVED one (wheel 2,
    // 3 gradients → enemy = 2 + 1 = 0 mod 3).
    {
        var elements: UiElementList = .empty;
        try buildEditorThemePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            definitions,
            theme,
            .{ .level_index = 0, .role = .enemy },
        );
        var current_button: ?Button = null;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_level_gradient and button.highlighted) {
                current_button = button;
            },
            else => {},
        };
        try std.testing.expect(current_button != null);
        try std.testing.expectEqual(@as(?u32, 0), current_button.?.editor_gradient);
    }
}

