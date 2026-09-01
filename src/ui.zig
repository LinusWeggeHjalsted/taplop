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
pub const material_count_font_size = ui_emit.material_count_font_size;
pub const cooldown_font_size = ui_emit.cooldown_font_size;
pub const overlay_font_size = ui_emit.overlay_font_size;
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
test "emitInspectorTextField via the content builder: current value unfocused, buffer + caret + selection while focused" {
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

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton Warrior", .sprite = "skeleton_1", .team = 1 },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // Unfocused: both fields show the current values; no caret/selection.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        const name_field = findTextField(&elements, .entity_name).?;
        try std.testing.expectEqualStrings("Skeleton Warrior", name_field.text);
        try std.testing.expect(name_field.caret == null);
        try std.testing.expect(name_field.selection == null);
        // The paper-strip treatment: lightest frame, PURE-black text
        // (literal 0,0,0 — the caret/selection follow the text color).
        try std.testing.expectEqual(theme.lightest, name_field.frame_color);
        try std.testing.expectEqual(types.Color{ .r = 0, .g = 0, .b = 0 }, name_field.text_color);
        try std.testing.expectEqual(
            types.TextFieldRef{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } },
            name_field.ref,
        );
        // The control line: full content width, flush with the content
        // region's left edge (the label sits on its own line above).
        try std.testing.expectEqual(
            editorInspectorPanelRect().x + ui_gap,
            name_field.screen_position.x,
        );
    }

    // Focused (name), with a selection + mid-string caret: the field shows
    // the BUFFER, the selection rect spans the selected glyphs, and the
    // caret sits at the measured prefix width.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        beginTextEdit(&ui_state, .{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } }, "Skeleton");
        // Type " W" (caret at 10), then select back two codepoints
        // (" W" selected: anchor 10, caret 8).
        const no_keys: [0]?[]const u8 = .{};
        _ = routeTextInput(&ui_state.text_edit.?, " W", &no_keys, &no_keys, false);
        const arrow_left: [2]?[]const u8 = .{ "ArrowLeft", "ArrowLeft" };
        _ = routeTextInput(&ui_state.text_edit.?, "", &arrow_left, &no_keys, true);
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        const name_field = findTextField(&elements, .entity_name).?;
        try std.testing.expectEqualStrings("Skeleton W", name_field.text);
        // Selection spans buffer glyphs 8..10, caret sits at index 8 — the
        // geometry is the metrics' own measurement of those slices (the
        // accumulation truncates once at the end, so per-glyph arithmetic
        // would drift; measure the same way the builder does).
        const buffer_text = ui_state.text_edit.?.buffer.currentText();
        const expected_selection_x = metrics.measureSpanWidth(text(buffer_text[0..8]), 64);
        const expected_selection_width = metrics.measureSpanWidth(text(buffer_text[8..10]), 64);
        try std.testing.expectEqual(expected_selection_x, name_field.selection.?.x);
        try std.testing.expectEqual(expected_selection_width, name_field.selection.?.width);
        try std.testing.expectEqual(expected_selection_x, name_field.caret.?.x);
    }
}

/// The first text field in `elements` whose ref id matches, for inspector
/// builder tests.
fn findTextField(elements: *const UiElementList, field_id: types.TextFieldId) ?TextFieldUi {
    for (elements.items) |element| switch (element) {
        .text_field => |field| if (std.meta.eql(field.ref.id, field_id)) return field,
        else => {},
    };
    return null;
}

test "inspector scalar controls: stat fields formatted, swatch row, toggle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const enemy_two: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{ black, black, enemy_two, black, black, black } },
        .player_gradient = .{ .colors = .{ black, .{ .r = 30, .g = 30, .b = 30 }, black, black, black, .{ .r = 40, .g = 40, .b = 40 } } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // Defaults: max_health 20, defense 0, speed 1, aggro_range 3,
    // displays_weapons true; color_index SET TO 2 (the highlighted swatch).
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1, .color_index = 2 },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // Scroll 10 — the Stats section's four numeric fields are the window
    // (the section-break spacer fills the tail): decimal-formatted values.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 10, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "- Stats", "Max health", "Defense", "Speed", "Aggro range" });
        try std.testing.expectEqualStrings("20", findTextField(&elements, .{ .entity_stat = .max_health }).?.text);
        try std.testing.expectEqualStrings("0", findTextField(&elements, .{ .entity_stat = .defense }).?.text);
        try std.testing.expectEqualStrings("1", findTextField(&elements, .{ .entity_stat = .speed }).?.text);
        try std.testing.expectEqualStrings("3", findTextField(&elements, .{ .entity_stat = .aggro_range }).?.text);
    }

    // The Color control (scroll 0 window): six swatch fills in the ENEMY
    // gradient + six payload buttons, the current index (2) highlighted.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var swatch_count: usize = 0;
        var highlighted_count: usize = 0;
        var swatch_fill_seen = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_color) {
                swatch_count += 1;
                if (button.highlighted) {
                    highlighted_count += 1;
                    try std.testing.expectEqual(@as(u32, 2), button.editor_color.?);
                }
            },
            .solid_rect => |rect| {
                // The enemy gradient's index-2 color is the swatch fill for
                // index 2 (the others are black — assert the distinctive one).
                if (std.meta.eql(rect.color, enemy_two)) swatch_fill_seen = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 6), swatch_count);
        try std.testing.expectEqual(@as(usize, 1), highlighted_count);
        try std.testing.expect(swatch_fill_seen);
    }

    // The Displays-weapons control: a full-width toggle showing the FORMAT
    // vocabulary ("true"), highlighted while true.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var toggle_button: ?Button = null;
        var saw_true_label = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .toggle_editor_entity_displays_weapons) {
                toggle_button = button;
            },
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "true")) saw_true_label = true;
            },
            else => {},
        };
        try std.testing.expect(toggle_button != null);
        // Half the control width (full-width reads as a section header),
        // and never highlighted (the true/false label carries the state).
        try std.testing.expectEqual(
            @divFloor(editorInspectorPanelRect().width - 2 * ui_gap, 2),
            toggle_button.?.width,
        );
        try std.testing.expect(!toggle_button.?.highlighted);
        try std.testing.expect(saw_true_label);
    }
}

test "decoration inspector content: identity + footprint rows, world-gradient swatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const world_three: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{ black, black, black, world_three, black, black } },
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
        .color_index = 3,
    }};
    const editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
    };

    var elements: UiElementList = .empty;
    var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
    try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);

    // Identity (Sprite + Color — a decoration's name IS its sprite path, no
    // name row) + Footprint (the read-only tile-count placeholder).
    try expectInspectorLabels(
        &elements,
        &.{ "- Identity", "Sprite", "stone_2", "Color", "- Footprint", "Footprint", "2 tiles" },
    );

    // The sprite button opens the shared picker (the input site routes the
    // kind by the inspector target).
    var saw_sprite_button = false;
    var swatch_count: usize = 0;
    var highlighted_count: usize = 0;
    var world_fill_seen = false;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.action == .open_editor_sprite_picker) saw_sprite_button = true;
            if (button.action == .select_editor_decoration_color) {
                swatch_count += 1;
                if (button.highlighted) {
                    highlighted_count += 1;
                    try std.testing.expectEqual(@as(u32, 3), button.editor_color.?);
                }
            }
        },
        .solid_rect => |rect| {
            // The WORLD gradient's index-3 color is the swatch fill for
            // index 3 (the others are black — assert the distinctive one).
            if (std.meta.eql(rect.color, world_three)) world_fill_seen = true;
        },
        else => {},
    };
    try std.testing.expect(saw_sprite_button);
    try std.testing.expectEqual(@as(usize, 6), swatch_count);
    try std.testing.expectEqual(@as(usize, 1), highlighted_count);
    try std.testing.expect(world_fill_seen);
}

test "inspector weapons + gear sections: type rows, add/delete, item fields when equipped" {
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

    // Main hand: an equipped sword. Coat: equipped. Everything else empty.
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{
            .name = "Skeleton",
            .team = 1,
            .main_hand_weapon = .{ .name = "Skeleton Sword", .weapon_type = .sword, .weapon_damage = 5 },
            .coat = .{ .name = "Skeleton Coat", .health_bonus = 2, .defense_bonus = 1 },
        },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // Units: Identity 9 + spacer, Stats 9 + spacer → Weapons header at 20.
    // Scroll 20 shows: the Weapons header, Main hand (equipped: type row +
    // Delete + its fields), Off hand (empty: type row, no Delete).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 20, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "- Weapons", "Main hand", "Delete", "Main hand name", "Main hand damage", "Off hand" });

        // The equipped weapon's fields carry its values.
        try std.testing.expectEqualStrings(
            "Skeleton Sword",
            findTextField(&elements, .{ .item_name = .main_hand }).?.text,
        );
        try std.testing.expectEqualStrings(
            "5",
            findTextField(&elements, .{ .item_stat = .{ .slot = .main_hand, .stat = .weapon_damage } }).?.text,
        );
        // No off-hand fields (the slot is empty).
        try std.testing.expect(findTextField(&elements, .{ .item_name = .off_hand }) == null);

        // Type cells: 12 total (two hands × 6), exactly one highlighted —
        // the main hand's sword. The main hand's row also carries a
        // Delete; the off hand's doesn't.
        var type_cells: usize = 0;
        var highlighted: ?types.GearSlot = null;
        var deletes: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .select_editor_weapon_type) {
                    type_cells += 1;
                    if (button.highlighted) highlighted = button.editor_gear_slot.?;
                    try std.testing.expect(button.editor_weapon_type != null);
                }
                if (button.action == .delete_editor_item and button.editor_gear_slot.? == .main_hand) {
                    deletes += 1;
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 12), type_cells);
        try std.testing.expectEqual(types.GearSlot.main_hand, highlighted.?);
        try std.testing.expectEqual(@as(usize, 1), deletes);
    }

    // The Gear section's items (scroll 30 — the window opens at the Gear
    // header): coat equipped → Delete + its fields; amulet empty → Add.
    // The coat's defense field doesn't fully fit the window.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 30, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "- Gear", "Amulet", "Add", "Coat", "Delete", "Coat name", "Coat health bonus" });

        var adds: usize = 0;
        var coat_deletes: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .add_editor_item and button.editor_gear_slot.? == .amulet) adds += 1;
                if (button.action == .delete_editor_item and button.editor_gear_slot.? == .coat) coat_deletes += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), adds);
        try std.testing.expectEqual(@as(usize, 1), coat_deletes);
        try std.testing.expectEqualStrings(
            "Skeleton Coat",
            findTextField(&elements, .{ .item_name = .coat }).?.text,
        );
        try std.testing.expectEqualStrings(
            "2",
            findTextField(&elements, .{ .item_stat = .{ .slot = .coat, .stat = .health_bonus } }).?.text,
        );
    }
}

test "editorInspectorTarget: active enemy/decoration/item tools pass through; tile falls back to the player" {
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 },
    }};
    const decoration_types = [_]types.DecorationTypeDef{.{ .id = "Tree" }};
    const item_types = [_]types.ItemTypeDef{.{ .id = "Gold" }};
    const levels = [_]types.EditorLevel{.{}};
    const base: types.Editor = .{
        .levels = &levels,
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
        .item_types = &item_types,
        .active_tool = .{ .entity_type = 0 },
    };
    try std.testing.expectEqual(EditorInspectorTarget{ .entity_type = 0 }, editorInspectorTarget(base));

    var tile_tool = base;
    tile_tool.active_tool = .tile;
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(tile_tool));

    var decoration_tool = base;
    decoration_tool.active_tool = .{ .decoration_type = 0 };
    try std.testing.expectEqual(
        EditorInspectorTarget{ .decoration_type = 0 },
        editorInspectorTarget(decoration_tool),
    );

    var item_tool = base;
    item_tool.active_tool = .{ .item_type = 0 };
    try std.testing.expectEqual(EditorInspectorTarget{ .item_type = 0 }, editorInspectorTarget(item_tool));

    // A stale active tool id (defensive) can't show anything.
    var stale_tool = base;
    stale_tool.active_tool = .{ .entity_type = 7 };
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(stale_tool));
    var stale_decoration_tool = base;
    stale_decoration_tool.active_tool = .{ .decoration_type = 7 };
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(stale_decoration_tool));
    var stale_item_tool = base;
    stale_item_tool.active_tool = .{ .item_type = 7 };
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(stale_item_tool));

    // An empty selection under the select tool → the player fallback.
    var select_tool = base;
    select_tool.active_tool = .select;
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(select_tool));
}

test "editorInspectorTarget: one shared enemy type wins; tiles and the '=' are ignored" {
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
        .{ .id = "Bat", .template = .{ .name = "Bat", .team = 1 } },
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 3, .y = 1 } },
        .{ .type_id = 1, .position = .{ .x = 5, .y = 2 } },
    } }};
    const resolve = struct {
        fn check(
            selection: []const types.Selectable,
        ) EditorInspectorTarget {
            return editorInspectorTarget(.{
                .levels = &levels,
                .entity_types = &entity_types,
                .active_tool = .select,
                .selection = selection,
            });
        }
    }.check;

    // One enemy → its type.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .entity_type = 0 },
        resolve(&.{.{ .entity_placement = 0 }}),
    );

    // Several enemies of the SAME type, mixed with tiles and the '='
    // (legitimately uninspectable — they contribute nothing) → still that
    // one type.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .entity_type = 0 },
        resolve(&.{
            .{ .tile = .{ .x = 1, .y = 1 } },
            .{ .entity_placement = 1 },
            .{ .level_end = {} },
            .{ .entity_placement = 0 },
        }),
    );

    // Two different enemy types → the player fallback.
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .entity_placement = 0 }, .{ .entity_placement = 2 } }),
    );

    // Tiles / the '=' only → nothing referenced → the player fallback.
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .tile = .{ .x = 0, .y = 0 } }, .{ .level_end = {} } }),
    );
}

test "editorInspectorTarget: selected decorations resolve to their type" {
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .team = 1 },
    }};
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "tree_1" },
        .{ .id = "ruin_1" },
    };
    const levels = [_]types.EditorLevel{.{ .decoration_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 2, .y = 2 } },
        .{ .type_id = 0, .position = .{ .x = 5, .y = 1 } },
        .{ .type_id = 1, .position = .{ .x = 8, .y = 0 } },
    }, .entity_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
    } }};
    const resolve = struct {
        fn check(
            selection: []const types.Selectable,
        ) EditorInspectorTarget {
            return editorInspectorTarget(.{
                .levels = &levels,
                .entity_types = &entity_types,
                .decoration_types = &decoration_types,
                .active_tool = .select,
                .selection = selection,
            });
        }
    }.check;

    // One decoration → its type.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .decoration_type = 0 },
        resolve(&.{.{ .decoration_placement = 0 }}),
    );

    // Several decorations of the SAME type → still that one type.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .decoration_type = 0 },
        resolve(&.{ .{ .decoration_placement = 0 }, .{ .decoration_placement = 1 } }),
    );

    // A decoration + an enemy → two distinct kinds → the player fallback.
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .decoration_placement = 0 }, .{ .entity_placement = 0 } }),
    );

    // An out-of-range placement index or a stale palette type id is an
    // unresolvable bug-state reference — fallback, not a crash (the
    // delete arms keep the selection consistent, so this is defensive).
    try std.testing.expectEqual(EditorInspectorTarget.player, resolve(&.{.{ .decoration_placement = 99 }}));

    const stale_levels = [_]types.EditorLevel{.{ .decoration_placements = &.{
        .{ .type_id = 7, .position = .{ .x = 0, .y = 0 } },
    } }};
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        editorInspectorTarget(.{
            .levels = &stale_levels,
            .decoration_types = &decoration_types,
            .active_tool = .select,
            .selection = &.{.{ .decoration_placement = 0 }},
        }),
    );
}

test "editorInspectorTarget: the '!' contributes a player reference" {
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
    } }};
    const resolve = struct {
        fn check(
            selection: []const types.Selectable,
        ) EditorInspectorTarget {
            return editorInspectorTarget(.{
                .levels = &levels,
                .entity_types = &entity_types,
                .active_tool = .select,
                .selection = selection,
            });
        }
    }.check;

    // The '!' alone → the player.
    try std.testing.expectEqual(EditorInspectorTarget.player, resolve(&.{.{ .player_start = {} }}));

    // The '!' + an enemy → two distinct references → the player (the
    // enemy does NOT win over the spawn).
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .entity_placement = 0 }, .{ .player_start = {} } }),
    );

    // The '!' mixed with tiles / the '=' → still the player.
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .tile = .{ .x = 2, .y = 2 } }, .{ .player_start = {} } }),
    );
}

test "editorInspectorTarget: unresolvable references force the player fallback" {
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .team = 1 },
    }};
    const item_types = [_]types.ItemTypeDef{.{ .id = "Gold" }};
    const levels = [_]types.EditorLevel{.{ .entity_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } },
    }, .item_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 2, .y = 2 } },
    } }};
    const resolve = struct {
        fn check(
            selection: []const types.Selectable,
        ) EditorInspectorTarget {
            return editorInspectorTarget(.{
                .levels = &levels,
                .entity_types = &entity_types,
                .item_types = &item_types,
                .active_tool = .select,
                .selection = selection,
            });
        }
    }.check;

    // A selected ground item resolves to its palette type (the item
    // content's target); mixed with a valid enemy (two distinct targets)
    // → the fallback.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .item_type = 0 },
        resolve(&.{.{ .ground_item_placement = 0 }}),
    );
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .entity_placement = 0 }, .{ .ground_item_placement = 0 } }),
    );

    // An out-of-range placement index or a stale palette type id is an
    // unresolvable bug-state reference — fallback, not a crash (the
    // delete arms keep the selection consistent, so this is defensive).
    try std.testing.expectEqual(EditorInspectorTarget.player, resolve(&.{.{ .entity_placement = 99 }}));
    try std.testing.expectEqual(EditorInspectorTarget.player, resolve(&.{.{ .ground_item_placement = 99 }}));

    const stale_levels = [_]types.EditorLevel{.{ .entity_placements = &.{
        .{ .type_id = 7, .position = .{ .x = 0, .y = 0 } },
    } }};
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        editorInspectorTarget(.{
            .levels = &stale_levels,
            .entity_types = &entity_types,
            .active_tool = .select,
            .selection = &.{.{ .entity_placement = 0 }},
        }),
    );

    const stale_item_levels = [_]types.EditorLevel{.{ .item_placements = &.{
        .{ .type_id = 7, .position = .{ .x = 0, .y = 0 } },
    } }};
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        editorInspectorTarget(.{
            .levels = &stale_item_levels,
            .item_types = &item_types,
            .active_tool = .select,
            .selection = &.{.{ .ground_item_placement = 0 }},
        }),
    );

    // The entity arm the content builder consumes: a valid inference
    // resolves, everything else nulls.
    try std.testing.expectEqual(
        @as(?u32, 0),
        editorInspectorEntityTarget(.{
            .levels = &levels,
            .entity_types = &entity_types,
            .active_tool = .select,
            .selection = &.{.{ .entity_placement = 0 }},
        }),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        editorInspectorEntityTarget(.{
            .levels = &levels,
            .entity_types = &entity_types,
            .active_tool = .select,
            .selection = &.{.{ .player_start = {} }},
        }),
    );
}

test "inspector item content: type rows, name + stat fields, ref targets" {
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

    const item_types = [_]types.ItemTypeDef{.{
        .id = "Iron Sword",
        .item = .{ .weapon = .{
            .name = "Iron Sword",
            .weapon_type = .sword,
            .weapon_damage = 5,
        } },
    }};
    const editor: types.Editor = .{
        .item_types = &item_types,
        .active_tool = .{ .item_type = 0 },
    };

    var elements: UiElementList = .empty;
    var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
    try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);

    // The name field: current value + the `.item_type` ref target.
    const name_field = findTextField(&elements, .item_def_name).?;
    try std.testing.expectEqualStrings("Iron Sword", name_field.text);
    try std.testing.expectEqual(
        types.TextFieldRef{ .id = .item_def_name, .target = .{ .item_type = 0 } },
        name_field.ref,
    );

    // The weapon's stat field: decimal value + the same target.
    const damage_field = findTextField(&elements, .{ .item_def_stat = .weapon_damage }).?;
    try std.testing.expectEqualStrings("5", damage_field.text);
    try std.testing.expectEqual(
        types.TextFieldRef{ .id = .{ .item_def_stat = .weapon_damage }, .target = .{ .item_type = 0 } },
        damage_field.ref,
    );

    // The type rows: 6 weapon cells + 5 gear cells, all carrying the
    // `.select_editor_item_type` action; the sword cell (the current
    // item) is the only highlighted one; weapon cells carry the weapon
    // type payload, gear cells don't.
    var pick_cells: usize = 0;
    var highlighted_kinds: usize = 0;
    var sword_icons: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_item_type) {
            pick_cells += 1;
            try std.testing.expect(button.editor_item_kind != null);
            if (button.editor_item_kind.? == .weapon) {
                try std.testing.expect(button.editor_weapon_type != null);
                if (button.highlighted) {
                    highlighted_kinds += 1;
                    try std.testing.expectEqual(types.WeaponType.sword, button.editor_weapon_type.?);
                }
            } else {
                try std.testing.expect(button.editor_weapon_type == null);
                try std.testing.expect(!button.highlighted);
            }
        },
        .image => |image| {
            if (std.mem.eql(u8, image.sprite_id, "items/sword")) sword_icons += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 11), pick_cells);
    try std.testing.expectEqual(@as(usize, 1), highlighted_kinds);
    try std.testing.expectEqual(@as(usize, 1), sword_icons);
}

test "inspector item content: per-kind stat fields; a skill tome renders bare rows" {
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

    // A coat (two stats) — the field set follows the kind.
    {
        const item_types = [_]types.ItemTypeDef{.{
            .id = "Leather Coat",
            .item = .{ .coat = .{ .name = "Leather Coat", .health_bonus = 3, .defense_bonus = 2 } },
        }};
        const editor: types.Editor = .{
            .item_types = &item_types,
            .active_tool = .{ .item_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqualStrings(
            "Leather Coat",
            findTextField(&elements, .item_def_name).?.text,
        );
        try std.testing.expectEqualStrings(
            "3",
            findTextField(&elements, .{ .item_def_stat = .health_bonus }).?.text,
        );
        try std.testing.expectEqualStrings(
            "2",
            findTextField(&elements, .{ .item_def_stat = .defense_bonus }).?.text,
        );
        // A stat the kind doesn't carry is never offered.
        try std.testing.expect(findTextField(&elements, .{ .item_def_stat = .weapon_damage }) == null);
    }

    // A skill tome (unreachable live — not authorable): no name field, no
    // stat fields, but the type rows still render (11 cells).
    {
        const item_types = [_]types.ItemTypeDef{.{
            .id = "Skill Tome",
            .item = .{ .skill_tome = .{ .skill = .slice, .value = 5 } },
        }};
        const editor: types.Editor = .{
            .item_types = &item_types,
            .active_tool = .{ .item_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expect(findTextField(&elements, .item_def_name) == null);
        var pick_cells: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .select_editor_item_type) pick_cells += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 11), pick_cells);
    }
}

test "textEditPressProceeds: M2 region is the open inspector panel + its toggle" {
    const rect = editorInspectorPanelRect();
    try std.testing.expectEqual(@as(i32, 0), rect.x);
    try std.testing.expectEqual(
        top_bar_height + ui_gap + editor_header_strip_height + ui_gap,
        rect.y,
    );
    try std.testing.expectEqual(editor_inspector_width, rect.width);

    const inside_panel: ScreenPosition = .{ .x = 512, .y = rect.y + 100 };
    const outside_panel: ScreenPosition = .{ .x = 1500, .y = rect.y + 100 };
    const over_viewport: ScreenPosition = .{ .x = 1500, .y = 1000 };

    // Inside the open panel → a sibling control; the press proceeds.
    try std.testing.expect(textEditPressProceeds(true, false, inside_panel, null));
    // Panel closed → only the toggle button itself proceeds.
    try std.testing.expect(!textEditPressProceeds(false, false, inside_panel, null));
    try std.testing.expect(textEditPressProceeds(false, false, inside_panel, .toggle_editor_inspector));
    // Outside the panel → pure dismissal, even over other UI (Undo).
    try std.testing.expect(!textEditPressProceeds(true, false, outside_panel, .undo));
    try std.testing.expect(!textEditPressProceeds(true, false, over_viewport, null));
    // Picker surfaces float OUTSIDE the panel rect but are the active
    // interaction — the press proceeds (commit + pick in one click).
    try std.testing.expect(textEditPressProceeds(true, false, outside_panel, .select_editor_utility_skill));
    try std.testing.expect(textEditPressProceeds(true, false, outside_panel, .close_editor_picker));
    // The metadata sidebar's rect + toggle behave the same (a sibling
    // control of a sidebar field).
    const sidebar_rect = editorMetadataSidebarPanelRect();
    const inside_sidebar: ScreenPosition = .{ .x = sidebar_rect.x + 100, .y = sidebar_rect.y + 100 };
    try std.testing.expect(textEditPressProceeds(false, true, inside_sidebar, null));
    try std.testing.expect(!textEditPressProceeds(false, false, inside_sidebar, null));
    try std.testing.expect(textEditPressProceeds(false, false, inside_sidebar, .toggle_editor_metadata_sidebar));
}

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

/// All entity sprites share one 512x640 frame (view.zig `entity_frame_*`).
/// Duplicated here because ui.zig can't import view.zig (view imports ui).
const editor_entity_frame_width: i32 = 512;
const editor_entity_frame_height: i32 = 640;

/// `world/tile_highlight.png` spritesheet: 4 frames of 256x256 in a
/// horizontal strip (frame N occupies x = N*256..N*256+256). The Select
/// tool graphic is frame 0.
const tile_highlight_frame_size: i32 = 256;

/// Font size for the editor palette group headers ("Enemies", …).
const editor_group_header_font_size: i32 = 64;

/// Height of the group header buttons and the editor "+" cells: 128.
/// Expanded groups' headers sit in a strip above the bar; collapsed
/// groups' headers + "+" sit flush against the bottom of the screen
/// (see `buildEditorBottomBar`).
const editor_header_strip_height: i32 = 128;

/// Side length of the square ui/panel "+" cells (palette group add-new,
/// level-tab add-level).
const editor_plus_size: i32 = 128;

/// Maximum type cells a palette group shows at once. Groups with more
/// types scroll horizontally (wheel over the group shifts the window;
/// see `UiState.editor_palette_scroll`).
pub const editor_palette_max_tools: usize = 8;

/// A palette group's type count: 0 = Enemies, 1 = Decorations, 2 = Ground
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
/// panels — neither matches), so detection matches those in the
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
fn scaleToFit(cell: Rectangle, sprite_width: i32, sprite_height: i32) Rectangle {
    if (sprite_width <= 0 or sprite_height <= 0) return cell;
    const scale = @min(
        @as(f32, @floatFromInt(cell.width)) / @as(f32, @floatFromInt(sprite_width)),
        @as(f32, @floatFromInt(cell.height)) / @as(f32, @floatFromInt(sprite_height)),
    );
    const fitted_width: i32 = @intFromFloat(@as(f32, @floatFromInt(sprite_width)) * scale);
    const fitted_height: i32 = @intFromFloat(@as(f32, @floatFromInt(sprite_height)) * scale);
    return cell.placeCenter(fitted_width, fitted_height);
}

/// Emit one editor tool cell: a `ui/button_background` Button tinted as a
/// button (player gradient index 5) carrying the tool's action + payload +
/// tooltip + input, with the tool's graphic scaled to fit (aspect-preserved,
/// centered, then multiplied by `graphic_scale`) on top — the icon passes
/// hover through to the button. Selecting the tool makes it active; the
/// ACTIVE tool's button is highlighted (lightest edge outline), as is the
/// hovered one via the generic hover pass in `view()`.
fn emitEditorToolCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    tool: types.EditorToolId,
    graphic_sprite_id: []const u8,
    graphic_source_rectangle: ?Rectangle,
    graphic_width: i32,
    graphic_height: i32,
    graphic_scale: f32,
    graphic_color: Color,
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
        .editor_tool = tool,
        .color = button_color,
        .highlighted = std.meta.eql(tool, active_tool),
        .tooltip = .{ .header = try spanRow(allocator, text(tooltip_header)) },
    } });
    // Fit the graphic at native dims, then shrink the fitted rect by
    // `graphic_scale`. (Scaling the INPUT dims is a no-op — scaleToFit
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
        .source_rectangle = graphic_source_rectangle,
        .blocks_input = false,
    } });
}

/// The small delete button flush in a palette tool cell's top-right corner
/// — the shared close-button visual (`close_button_sprite_id`, the picker
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
        .editor_tool = tool,
        .tooltip = .{ .header = try spanRow(allocator, text(
            try std.fmt.allocPrint(allocator, "Delete {s} + its placements", .{type_name}),
        )) },
    } });
}

/// Editor top row: level tabs, emitted to the RIGHT of the top bar's
/// options + undo buttons (those come from `buildTopBar` — same locations
/// as levels/hubs). One 128-high panel-backed button per level (the
/// palette group-header visual class), labeled with the level's name or
/// "Level N" if unnamed. The ACTIVE tab is highlighted (lightest edge
/// outline — the same path as tool cells); clicking switches the active
/// level (payload = level index → `.select_editor_level` →
/// `player_set_editor_level`, which rides the undo timeline). Each tab
/// carries a small close-button (the shared `ui/close_button` class) flush
/// in its top-right corner — `.delete_editor_level` deletes the level;
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

    // Tabs start right of the top bar's two cells (options + undo joined
    // by ui_gap in buildTopBar's Row; one more gap separates the tabs),
    // flush against the top of the screen, and end at the pinned add-level
    // "+" — one ui_gap clear of it, one clear of the primary-actions block.
    const region_left: i32 = 2 * (slot_size + ui_gap);
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

    // Scroll clamp (authoritative, in place — the builder knows the tab
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

    // Active-tab follow — ONLY on a change of the active tab (tracked via
    // `editor_level_tab_last_active`): the add-level flow switches to the
    // newly created LAST tab ("the author lands on the thing they just
    // created"), which a scrolled window would hide. Firing on every
    // frame would snap the window back to the active tab and make manual
    // scrolling impossible, so the follow scrolls the minimum distance
    // that brings the active tab into the window exactly once per change
    // — never past the clamp above.
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
    // window model — offscreen tabs can't be clicked). The FIRST visible
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
            .editor_level = @intCast(index),
            .highlighted = index == editor.active_level_index,
            .tooltip = .{ .header = try spanRow(allocator, text(label)) },
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            // Centered in the zone LEFT of the delete button, not the
            // full tab — the × owns the top-right corner.
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
        } });
        // The tab's × (delete level): the shared close-button visual, flush
        // in the tab's top-right corner, emitted AFTER the tab so hit-
        // testing (last-wins) prefers it where the two overlap. Offered
        // only while the mission has more than one level — a mission
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
                .editor_level = @intCast(index),
                .tooltip = .{ .header = try spanRow(allocator, text("Delete level")) },
            } });
        }

        x += width + ui_gap;
    }

    // Add-level "+": square panel cell PINNED flush at the row's right
    // edge (always reachable while the tab window scrolls) — a BUTTON
    // (spriteless over the panel, the group-header class):
    // `.add_editor_level` appends the template level + switches to it.
    try emitEditorPlusCell(
        elements,
        allocator,
        font_metrics,
        plus_cell,
        button_color,
        active_theme.lightest,
        "Add level",
        .add_editor_level,
        null,
    );
}

/// The top-right primary-actions block's total width (Test + Validate:
/// two `slot_size` cells + the separating gap). Shared by the buttons
/// builder, the level-tab row's right bound, and the tab wheel-scroll
/// region so the three can't drift.
pub const editor_primary_actions_width: i32 = 2 * slot_size + ui_gap;

/// The level-tab strip's wheel-scroll region: from the tab row's left
/// edge (right of the top bar's options + undo cells) to the
/// primary-actions block, top-aligned with the tabs. One wheel notch over
/// it scrolls the tab window by one tab (`UiState.editor_level_tab_scroll`).
pub fn editorLevelTabScrollRegion() Rectangle {
    const left: i32 = 2 * (slot_size + ui_gap);
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
/// top bar's height, flush against the right screen edge — the visual
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
    // block's total width is `editor_primary_actions_width` — the shared
    // bound the level-tab row clamps against.
    const validate_cell: Rectangle = .{
        .x = types.reference_width - slot_size,
        .y = 0,
        .width = slot_size,
        .height = slot_size,
    };
    const test_cell: Rectangle = .{
        .x = validate_cell.x - slot_size - ui_gap,
        .y = 0,
        .width = slot_size,
        .height = slot_size,
    };

    try emitIconButton(
        elements,
        allocator,
        test_cell,
        button_background_sprite_id,
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
        button_background_sprite_id,
        "ui/icon_validate",
        .validate_editor_mission,
        .{ .header = try spanRow(allocator, text("Validate (play the whole mission)")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );
}

/// Width of the editor inspector sidebar's background panel. Placeholder
/// value — revisit once the field layout lands and the real width is
/// visible.
pub const editor_inspector_width: i32 = 1024;

/// The Inventory section's slot-grid width: six square 128px cells fit a
/// row with room for the gap rhythm; 16 rows × 6 = the full
/// `inventory_slot_count` (the same 96 slots the in-game 8×12 grid
/// shows — intentionally identical capacity, arranged to fit the panel).
pub const editor_inventory_slots_per_row: u32 = 6;
pub const editor_inventory_row_count: u32 = types.inventory_slot_count / editor_inventory_slots_per_row;

/// The inspector background panel's rect — the single source for the
/// builder's layout AND the M2 press arbitration (DESIGN → UI Framework →
/// Text input widget), so the two can't drift.
pub fn editorInspectorPanelRect() Rectangle {
    const top = top_bar_height + ui_gap + editor_header_strip_height + ui_gap;
    const bottom = types.reference_height -
        bottom_bar_height - 2 * ui_gap - editor_header_strip_height;
    return .{ .x = 0, .y = top, .width = editor_inspector_width, .height = bottom - top };
}

/// Editor inspector sidebar (the left bar): a top-left "Inspector" toggle
/// button flush below the options button (the level-tab / group-header
/// visual class: panel-backed, `editor_header_strip_height` tall, label +
/// side padding wide), and — when open — a background panel underneath it
/// that will host the active tool's field editors (later slices; empty for
/// now). The panel spans from below the button down to one `ui_gap` above
/// the expanded palette groups' header strip (those headers sit `ui_gap` +
/// one strip above the bottom bar; the extra gap keeps the panel from
/// sitting flush against them — their x range overlaps the panel since the
/// bottom bar is flush left). The open flag lives on the Editor (GameState)
/// — the toggle rides the undo timeline via `editor_toggle_inspector`.
/// See DESIGN → Architecture → Level Editor → Editor UI layout (inspector).
pub fn buildEditorInspectorPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    inspector_open: bool,
    ui_state: *UiState,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // Toggle button: flush left, below the top bar's options button.
    const label = "Inspector";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    const width = @max(label_width + 2 * ui_gap, editor_header_strip_height);
    const button_cell: Rectangle = .{
        .x = 0,
        .y = top_bar_height + ui_gap,
        .width = width,
        .height = editor_header_strip_height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_header_strip_height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = null,
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_header_strip_height,
        .action = .toggle_editor_inspector,
        .tooltip = .{ .header = try spanRow(allocator, text(label)) },
    } });
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = button_cell.placeCenter(label_width, editor_group_header_font_size).position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    // Background panel (when open): from below the button to one ui_gap
    // above the expanded palette groups' header strip. Theme darkest —
    // the background-panel class (button panels tint gradient[5] to read
    // as buttons against it).
    if (inspector_open) {
        const panel_rect = editorInspectorPanelRect();
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = panel_rect.position(),
            .width = panel_rect.width,
            .height = panel_rect.height,
            .color = active_theme.darkest,
        } });
        try buildEditorInspectorContent(
            elements,
            allocator,
            font_metrics,
            editor,
            active_theme,
            ui_state,
        );
    }
}

/// The editor's centered picker OVERLAY: the band between the two
/// sidebars — full sidebar-panel height, a `ui_gap` in from each sidebar
/// panel's edge. CONSTANT (independent of the sidebars' open state — the
/// pickers keep their rect regardless; the gameplay scenes' middle-panel
/// band is the model). The pickers' CONTENTS are fixed-size (256px cells,
/// fixed strips) laid out inside it — the overlay never resizes with its
/// content. See DESIGN → Architecture → Level Editor → Editor UI layout.
pub fn editorPickerOverlayRect() Rectangle {
    const top = top_bar_height + ui_gap + editor_header_strip_height + ui_gap;
    const bottom = types.reference_height -
        bottom_bar_height - 2 * ui_gap - editor_header_strip_height;
    return .{
        .x = editor_metadata_sidebar_width + ui_gap,
        .y = top,
        .width = types.reference_width - 2 * editor_metadata_sidebar_width - 2 * ui_gap,
        .height = bottom - top,
    };
}

/// Width of the editor metadata sidebar's background panel (mirrors the
/// inspector's placeholder width).
pub const editor_metadata_sidebar_width: i32 = 1024;

/// The metadata sidebar's panel rect — the inspector rect mirrored to the
/// right edge. Single source for the builder's layout AND the M2 press
/// arbitration, so the two can't drift.
pub fn editorMetadataSidebarPanelRect() Rectangle {
    const top = top_bar_height + ui_gap + editor_header_strip_height + ui_gap;
    const bottom = types.reference_height -
        bottom_bar_height - 2 * ui_gap - editor_header_strip_height;
    return .{
        .x = types.reference_width - editor_metadata_sidebar_width,
        .y = top,
        .width = editor_metadata_sidebar_width,
        .height = bottom - top,
    };
}

/// Editor metadata sidebar (the right bar): a top-right "Settings" toggle
/// button at the inspector toggle's height, flush to the right screen edge
/// (the same visual class), and — when open — a background panel hosting
/// the mission + active-level metadata: the Mission section (name field)
/// and the Level section (name field; the gradient rows land with the
/// theme slice). The open flag lives on the Editor (GameState) — the
/// toggle rides the undo timeline via `editor_toggle_metadata_sidebar`.
/// See DESIGN → Architecture → Level Editor → Editor UI layout (Settings
/// sidebar).
pub fn buildEditorMetadataSidebar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    metadata_sidebar_open: bool,
    ui_state: *UiState,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // Toggle button: flush right, at the inspector toggle's height.
    const label = "Metadata";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    const width = @max(label_width + 2 * ui_gap, editor_header_strip_height);
    const button_cell: Rectangle = .{
        .x = types.reference_width - width,
        .y = top_bar_height + ui_gap,
        .width = width,
        .height = editor_header_strip_height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_header_strip_height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = null,
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_header_strip_height,
        .action = .toggle_editor_metadata_sidebar,
        .tooltip = .{ .header = try spanRow(allocator, text(label)) },
    } });
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = button_cell.placeCenter(label_width, editor_group_header_font_size).position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    if (!metadata_sidebar_open) return;

    const panel_rect = editorMetadataSidebarPanelRect();
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = panel_rect.position(),
        .width = panel_rect.width,
        .height = panel_rect.height,
        .color = active_theme.darkest,
    } });

    // Content: the INSPECTOR'S EXACT MODEL — a per-frame entry list over
    // the expansion state, view-relative windowed emission (only rows
    // that FULLY fit), and a scrollbar when the content overflows. Both
    // sections COLLAPSED by default; the strips are the shared
    // collapsible section headers (`emitInspectorSectionStrip` — the +/-
    // marker, the whole-strip click, the shared expansion array keyed by
    // `EditorInspectorSectionId`).
    const content: Rectangle = .{
        .x = panel_rect.x + ui_gap,
        .y = panel_rect.y + ui_gap,
        .width = panel_rect.width - 2 * ui_gap,
        .height = panel_rect.height - 2 * ui_gap,
    };
    const visible_rows = @divFloor(content.height, editor_inspector_row_height);
    const scroll_offset = &ui_state.editor_metadata_scroll;

    // The level the sidebar shows (the ACTIVE tab). The level index rides
    // the name field's ref target (a mid-edit tab switch can't retarget
    // the commit). A level-less editor (defensive — open_editor
    // guarantees ≥1) shows an empty field whose commit gates on the
    // index bound.
    const active_level: usize = @min(editor.active_level_index, editor.levels.len);
    const level: ?types.EditorLevel = if (active_level < editor.levels.len)
        editor.levels[active_level]
    else
        null;
    const entries: []const EditorMetadataEntry = try editorMetadataEntries(
        allocator,
        level,
        active_theme,
        &ui_state.editor_inspector_section_expanded,
    );

    // Unit math + scroll clamp — the inspector's (authoritative here: the
    // builder knows the content height).
    var total_units: i32 = 0;
    for (entries) |entry| total_units += editorMetadataEntryUnits(entry);
    const max_scroll_row = @max(@as(i32, 0), total_units - visible_rows);
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;

    const text_edit: ?*const TextEditState =
        if (ui_state.text_edit != null) &ui_state.text_edit.? else null;

    // Windowed emission (the skills-panel model, variable-height entries):
    // an entry is emitted only when it FULLY fits the visible window.
    var start_unit: i32 = 0;
    var index: usize = 0;
    while (index < entries.len and start_unit < scroll_offset.* + visible_rows) : (index += 1) {
        const entry = entries[index];
        const units = editorMetadataEntryUnits(entry);
        defer start_unit += units;
        if (start_unit < scroll_offset.* or
            start_unit + units > scroll_offset.* + visible_rows) continue;
        const cell: Rectangle = .{
            .x = content.x,
            .y = content.y + (start_unit - scroll_offset.*) * editor_inspector_row_height,
            .width = content.width,
            .height = units * editor_inspector_row_height,
        };
        switch (entry) {
            // A blank unit — the section-break gap.
            .spacer => {},
            .section => |section_id| try emitInspectorSectionStrip(
                elements,
                allocator,
                cell,
                section_id,
                ui_state.editor_inspector_section_expanded[@intFromEnum(section_id)],
                button_color,
                active_theme,
            ),
            .mission_name => try emitSidebarNameField(
                elements,
                allocator,
                font_metrics,
                text_edit,
                .{ .id = .mission_name, .target = .mission },
                editor.mission.name,
                cell,
                active_theme,
            ),
            .level_name => try emitSidebarNameField(
                elements,
                allocator,
                font_metrics,
                text_edit,
                .{ .id = .level_name, .target = .{ .level = @intCast(active_level) } },
                if (level) |some_level| some_level.name else "",
                cell,
                active_theme,
            ),
            .gradient => |row| try emitSidebarGradientRow(
                elements,
                allocator,
                row,
                button_color,
                cell,
                active_theme,
            ),
        }
    }

    // Scrollbar (only when the content overflows): the inspector's
    // geometry — track + proportional thumb in the right `ui_gap` margin,
    // measured in row units.
    if (total_units > visible_rows) {
        const track_x = panel_rect.x + panel_rect.width - ui_gap +
            @divFloor(ui_gap - editor_inspector_scrollbar_width, 2);
        const track_y = content.y;
        const track_height = visible_rows * editor_inspector_row_height;
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = track_y },
            .width = editor_inspector_scrollbar_width,
            .height = track_height,
            .color = .{ .r = 80, .g = 80, .b = 80 },
        } });
        const thumb_height = @max(
            @as(i32, 40),
            @divTrunc(track_height * visible_rows, total_units),
        );
        const thumb_y = track_y +
            @divTrunc(scroll_offset.* * (track_height - thumb_height), max_scroll_row);
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = thumb_y },
            .width = editor_inspector_scrollbar_width,
            .height = thumb_height,
            .color = .{ .r = 180, .g = 180, .b = 180 },
        } });
    }
}

/// One row of the metadata sidebar's content plan. Mirrors the inspector's
/// entry model: a SECTION header (1 unit, the shared collapsible strip),
/// a section-break SPACER (1 unit), or a two-unit field entry (label line
/// above, control below).
const EditorMetadataEntry = union(enum) {
    section: types.EditorInspectorSectionId,
    spacer: void,
    mission_name: void,
    level_name: void,
    /// One gradient row (see `EditorGradientRow`).
    gradient: EditorGradientRow,
};

/// One gradient row of the metadata sidebar's Current-level section: the
/// role's label + effective gradient + the override state (null =
/// auto-deriving).
const EditorGradientRow = struct {
    label: []const u8,
    role: types.LevelGradientRole,
    colors: [types.gradient_color_count]types.Color,
    gradient_override: ?u32,
};

/// Row units a metadata entry occupies: a section header / spacer is one;
/// the field entries are two (the label line + the control line).
fn editorMetadataEntryUnits(entry: EditorMetadataEntry) i32 {
    return switch (entry) {
        .section, .spacer => 1,
        .mission_name, .level_name, .gradient => 2,
    };
}

/// The metadata sidebar's content plan: the Mission section (the mission's
/// name) then the Current-level section (the active level's name + the
/// three gradient rows). Each section header is followed by its children
/// WHILE EXPANDED (the shared `editor_inspector_section_expanded` state —
/// collapse is a view affordance, off the undo timeline). The spacer
/// belongs to the section ABOVE it (a collapsed section takes no gap).
fn editorMetadataEntries(
    allocator: std.mem.Allocator,
    level: ?types.EditorLevel,
    active_theme: types.ActiveColorTheme,
    expanded: *const [editor_inspector_section_count]bool,
) ![]const EditorMetadataEntry {
    var entries: std.ArrayList(EditorMetadataEntry) = .empty;

    try entries.append(allocator, .{ .section = .mission });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.mission)]) {
        try entries.append(allocator, .mission_name);
        try entries.append(allocator, .spacer);
    }

    try entries.append(allocator, .{ .section = .current_level });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.current_level)]) {
        try entries.appendSlice(allocator, &.{
            .level_name,
            .{ .gradient = .{
                .label = "World colors",
                .role = .world,
                .colors = active_theme.world_gradient.colors,
                .gradient_override = null,
            } },
            .{ .gradient = .{
                .label = "Enemy colors",
                .role = .enemy,
                .colors = active_theme.enemy_gradient.colors,
                .gradient_override = if (level) |some_level|
                    some_level.enemy_gradient_index
                else
                    null,
            } },
            .{ .gradient = .{
                .label = "Player colors",
                .role = .player,
                .colors = active_theme.player_gradient.colors,
                .gradient_override = if (level) |some_level|
                    some_level.player_gradient_index
                else
                    null,
            } },
        });
    }

    return entries.items;
}

/// A metadata-sidebar gradient row (two-unit field entry, the inspector's
/// geometry): the role label line above, the control line below — the
/// AUTO toggle (enemy/player roles only) then the full-gradient swatch
/// strip, ONE button over the whole strip opening the theme picker.
/// `gradient_override` is null while the role auto-derives. The outline
/// marks the mode: the AUTO button while deriving, the SWATCH while an
/// explicit pick is in force (the world row's swatch always). The swatch
/// colors are the EFFECTIVE gradient either way (the active theme
/// already resolved them).
fn emitSidebarGradientRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    row: EditorGradientRow,
    button_color: types.Color,
    entry: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    // The descriptor line (the role's label), flush to the bottom of the
    // upper unit — the inspector's field-entry convention.
    try elements.append(allocator, .{ .text_label = .{
        .text = row.label,
        .screen_position = .{ .x = entry.x, .y = inspectorLabelY(entry) },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
    const control_rect = inspectorControlRect(entry);
    const role = row.role;
    const gradient_override = row.gradient_override;

    // The AUTO toggle (enemy/player rows only): highlighted while
    // deriving; a click while manual reverts (the input layer no-ops it
    // while auto — the same-value rule).
    var swatch_rect = control_rect;
    if (role != .world) {
        const auto_rect: Rectangle = .{
            .x = control_rect.x,
            .y = control_rect.y,
            .width = @divFloor(control_rect.width, 4),
            .height = control_rect.height,
        };
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = auto_rect.position(),
            .width = auto_rect.width,
            .height = auto_rect.height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .screen_position = auto_rect.position(),
            .width = auto_rect.width,
            .height = auto_rect.height,
            .action = .toggle_editor_level_gradient_auto,
            .editor_gradient_role = role,
            .highlighted = gradient_override == null,
            .tooltip = .{ .header = try spanRow(allocator, text(
                "Derive from world gradient",
            )) },
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = "Auto",
            .screen_position = .{
                .x = auto_rect.x + ui_gap,
                .y = auto_rect.y + @divFloor(auto_rect.height - editor_group_header_font_size, 2),
            },
            .font_size = editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        swatch_rect = .{
            .x = control_rect.x + auto_rect.width + ui_gap,
            .y = control_rect.y,
            .width = control_rect.width - auto_rect.width - ui_gap,
            .height = control_rect.height,
        };
    }

    // The full-gradient swatch strip: 6 equal color blocks + ONE
    // invisible button over the whole strip (opens the theme picker).
    const block_width = @divFloor(swatch_rect.width, types.gradient_color_count);
    for (0..types.gradient_color_count) |index| {
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{
                .x = swatch_rect.x + @as(i32, @intCast(index)) * block_width,
                .y = swatch_rect.y,
            },
            .width = block_width,
            .height = swatch_rect.height,
            .color = row.colors[index],
        } });
    }
    try elements.append(allocator, .{ .button = .{
        .screen_position = swatch_rect.position(),
        .width = swatch_rect.width,
        .height = swatch_rect.height,
        .action = .open_editor_level_gradient_picker,
        .editor_gradient_role = role,
        // The outline marks the row's mode: the AUTO button carries it
        // while deriving, the SWATCH while an explicit pick is in force
        // (the world row's swatch always — its index is always picked).
        // The backend renders it as the lightest stroked rect.
        .highlighted = role == .world or gradient_override != null,
        .tooltip = .{ .header = try spanRow(allocator, text("Pick gradient")) },
    } });
}

/// A sidebar name field: the inspector field-entry geometry (label line
/// above, paper-strip control below) over the shared `emitTextFieldUi`.
/// `entry` is the two-unit cell (label unit + control unit).
fn emitSidebarNameField(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    text_edit: ?*const TextEditState,
    ref: types.TextFieldRef,
    current_value: []const u8,
    entry: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    try elements.append(allocator, .{ .text_label = .{
        .text = "Name",
        .screen_position = .{ .x = entry.x, .y = inspectorLabelY(entry) },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
    try emitTextFieldUi(
        elements,
        allocator,
        font_metrics,
        text_edit,
        ref,
        current_value,
        inspectorControlRect(entry),
        active_theme,
    );
}

/// Inspector content row pitch — the 128px UNIT: a section header is one
/// unit; a field entry is TWO (the label line above, the editable value
/// below — one thing per line, full width).
pub const editor_inspector_row_height: i32 = editor_header_strip_height;

/// Inspector scrollbar track width, centered in the panel's right `ui_gap`
/// margin (the skills-panel precedent).
pub const editor_inspector_scrollbar_width: i32 = 12;

/// Inset of a control line within its row unit. Halved from `ui_gap` so
/// the label line sits CLOSE to its editable value (the header reads as
/// belonging to the field, not floating).
const editor_inspector_control_gap: i32 = @divFloor(ui_gap, 2);

/// The control line's rect inside a two-unit entry cell: the lower row
/// unit, inset by `editor_inspector_control_gap` (the label sits flush
/// above it at the unit's bottom).
fn inspectorControlRect(cell: Rectangle) Rectangle {
    return .{
        .x = cell.x,
        .y = cell.y + editor_inspector_row_height + editor_inspector_control_gap,
        .width = cell.width,
        .height = editor_inspector_row_height - 2 * editor_inspector_control_gap,
    };
}

/// The label line's y inside a two-unit entry cell: flush to the BOTTOM of
/// the upper unit, directly above the control line.
fn inspectorLabelY(cell: Rectangle) i32 {
    return cell.y + editor_inspector_row_height - editor_group_header_font_size;
}

/// What the editor inspector is currently showing. The player is the
/// FALLBACK: any state that doesn't resolve to exactly one enemy,
/// decoration, or item type shows the player (the '!' spawn's loadout).
pub const EditorInspectorTarget = union(enum) {
    entity_type: u32,
    decoration_type: u32,
    item_type: u32,
    player: void,
};

/// The inspector's target: the ACTIVE placement tool (enemy, decoration,
/// or item), or — while the select tool is active — the tool INFERRED
/// from the selection. The player is the fallback for everything else:
/// the tile tool, an empty or ambiguous selection, an unresolvable
/// reference. Inference rules: tiles and the '=' contribute NOTHING
/// (legitimately uninspectable — mixing them with enemies still shows the
/// enemy); the '!' contributes a `.player` REFERENCE (so player-start +
/// anything — or alone — resolves to the player); entity, decoration,
/// and ground-item placements contribute their type, resolved against
/// the ACTIVE level — an out-of-range placement index or a stale palette
/// type id is an unresolvable bug-state reference and forces the fallback
/// (the delete arms keep the selection consistent, so this is defensive
/// only — see `Selectable`). Exactly one distinct reference wins; two or
/// more (e.g. two enemy types, or an enemy plus a decoration) fall back
/// to the player. See DESIGN → Architecture → Level Editor → Selection
/// model (Inspector tool-type inference).
pub fn editorInspectorTarget(editor: types.Editor) EditorInspectorTarget {
    switch (editor.active_tool) {
        // The select tool infers from the selection below.
        .select => {},
        .entity_type => |type_id| return if (type_id < editor.entity_types.len)
            .{ .entity_type = type_id }
        else
            .player,
        .decoration_type => |type_id| return if (type_id < editor.decoration_types.len)
            .{ .decoration_type = type_id }
        else
            .player,
        .item_type => |type_id| return if (type_id < editor.item_types.len)
            .{ .item_type = type_id }
        else
            .player,
        // The tile tool has no fields — the player is the fallback.
        .tile => return .player,
    }
    if (editor.active_level_index >= editor.levels.len) return .player;
    const level = editor.levels[editor.active_level_index];
    var inferred: ?EditorInspectorTarget = null;
    for (editor.selection) |selected| {
        const referenced: ?EditorInspectorTarget = switch (selected) {
            // Legitimately uninspectable — contributes nothing (mixing
            // tiles / the '=' with enemies still shows the enemy).
            .tile, .level_end => null,
            .player_start => .player,
            .entity_placement => |index| blk: {
                // An out-of-range placement index or a stale palette type
                // id is an unresolvable bug-state reference — it can't
                // show anything, so it forces the fallback (defensive
                // only; the placement arms keep both valid). A VALID
                // reference contributes below (break) so later entries
                // still get compared against it.
                if (index >= level.entity_placements.len) return .player;
                const type_id = level.entity_placements[index].type_id;
                if (type_id >= editor.entity_types.len) return .player;
                break :blk .{ .entity_type = type_id };
            },
            .decoration_placement => |index| blk: {
                // Same defensive posture as the entity arm.
                if (index >= level.decoration_placements.len) return .player;
                const type_id = level.decoration_placements[index].type_id;
                if (type_id >= editor.decoration_types.len) return .player;
                break :blk .{ .decoration_type = type_id };
            },
            .ground_item_placement => |index| blk: {
                // Same defensive posture as the entity arm.
                if (index >= level.item_placements.len) return .player;
                const type_id = level.item_placements[index].type_id;
                if (type_id >= editor.item_types.len) return .player;
                break :blk .{ .item_type = type_id };
            },
        };
        const target = referenced orelse continue;
        if (inferred) |existing| {
            if (!editorInspectorTargetsEqual(existing, target)) return .player;
        } else {
            inferred = target;
        }
    }
    return inferred orelse .player;
}

fn editorInspectorTargetsEqual(
    first: EditorInspectorTarget,
    second: EditorInspectorTarget,
) bool {
    if (std.meta.activeTag(first) != std.meta.activeTag(second)) return false;
    return switch (first) {
        .player => true,
        .entity_type => |type_id| type_id == second.entity_type,
        .decoration_type => |type_id| type_id == second.decoration_type,
        .item_type => |type_id| type_id == second.item_type,
    };
}

/// The entity (enemy) type the inspector currently edits, or null when
/// the resolved target (see `editorInspectorTarget`) is the player, a
/// decoration type, or an item type. File-private: the inspector content
/// builder is the only consumer — the input-side commit sites map the
/// full target instead (the player arm edits `player_def`, the
/// decoration arm edits the decoration palette).
fn editorInspectorEntityTarget(editor: types.Editor) ?u32 {
    return switch (editorInspectorTarget(editor)) {
        .entity_type => |type_id| if (type_id < editor.entity_types.len) type_id else null,
        .decoration_type, .item_type, .player => null,
    };
}

/// The control a field entry hosts (the editable value line, below the
/// label). Controls land per slice; `none` entries render label-only until
/// theirs.
const EditorInspectorControl = union(enum) {
    none,
    text: types.TextFieldId,
    /// The base-sprite row (enemy identity): a button showing the current
    /// stem that opens the centered sprite picker (mission-local +
    /// official tabs — see DESIGN → Level Editor → Editor UI layout, the
    /// centered sprite picker).
    sprite_button: void,
    /// The color_index swatch row (the enemy gradient, one swatch per
    /// index — the settings screen's player-color row is the precedent).
    swatches,
    /// The displays_weapons true/false toggle.
    toggle,
    /// The decoration content's sprite row — same button look as the
    /// entity `sprite_button`, reading the decoration context instead.
    decoration_sprite_button: void,
    /// The decoration content's color swatch row (the WORLD gradient —
    /// decorations index into it, matching the in-game tinting).
    decoration_swatches: void,
    /// The decoration content's footprint row: a button showing the tile
    /// count that opens the centered footprint editor (the tile-grid
    /// picker).
    footprint_button: void,
    /// A palette item TYPE's field (the Items group's content — name or
    /// one stat): the shared text-field element, reading the item context
    /// instead of an entity template.
    item_text: types.TextFieldId,
    /// An INVENTORY slot item's field (the player content's Inventory
    /// section detail rows — name or one stat): the shared text-field
    /// element, reading the selected slot's item.
    inventory_item_text: types.TextFieldId,
};

/// One line of inspector content — per the coupling contract in DESIGN →
/// Architecture → Level Editor → Editor UI layout → Inspector fields. The
/// list is built PER FRAME from the editor state (a present item adds its
/// sub-field rows after its slot row). Sections carry their identity (not
/// a label string): the id keys the expansion state + the label lookup.
const EditorInspectorEntry = union(enum) {
    section: types.EditorInspectorSectionId,
    /// One blank unit before every section header except the first — the
    /// section break reads as a break, not just a different strip.
    spacer: void,
    field: struct {
        label: []const u8,
        control: EditorInspectorControl,
    },
    /// A weapon slot: the label line + the weapon-type row (a pick creates
    /// while empty / retypes in place) + Delete while a weapon is equipped.
    weapon_slot: types.GearSlot,
    /// A non-weapon gear slot: the label line + Add (while empty) / Delete
    /// (while equipped); a present item's name/stat field entries follow.
    gear_slot: types.GearSlot,
    /// The utility-skill bar: the label line + ONE row of five 128×128
    /// skill slots (occupied = skill button + icon, empty = the diamond
    /// marker), each opening the centered picker.
    utility_skill_row: void,
    /// The player loadout's name — a READ-ONLY value line (the name comes
    /// with the imported player data, it isn't hand-edited).
    player_name_line: void,
    /// The player inspector's Import button: copy the session's player
    /// data (or the new-game default, with none) into the loadout.
    import_player: void,
    /// One ROW of the player loadout's inventory slot grid (six cells;
    /// `editor_inventory_slots_per_row`). While the section's selected
    /// slot sits in this row, the detail entries follow directly below
    /// (the per-frame insert — see editorInspectorPlayerEntries).
    inventory_slot_row: u32,
    /// The selected inventory slot's Add/Delete row: the "Slot N" label
    /// line + the half-width button (Add while the slot is empty, Delete
    /// while an item is present). The FIRST detail entry below the
    /// selected slot's row.
    inventory_item_button: u32,
    /// The selected inventory slot's type-pick rows (3 units: the "Type"
    /// label line + the weapon row + the gear-kind row) — emitted ONLY
    /// while an item exists in the slot (author decision: an empty slot
    /// shows Add until an item does).
    inventory_item_type_rows: void,
    /// One ENEMY layer's slot row (label "Layer N"): the sprite-stem
    /// button (re-pick via the layer picker) + Delete. The Layers section
    /// is enemy content only — the player loadout has no layers.
    entity_layer: u32,
    /// One enemy layer's color swatch row (the enemy gradient).
    entity_layer_color: u32,
    /// The enemy content's add-layer row (opens the picker in add mode).
    add_entity_layer: void,
    /// One DECORATION layer's slot row — the entity_layer shape over the
    /// decoration context.
    decoration_layer: u32,
    /// One decoration layer's color swatch row (the world gradient).
    decoration_layer_color: u32,
    /// The decoration content's add-layer row.
    add_decoration_layer: void,
    /// The item content's type-pick rows (3 units): the "Type" label line
    /// + the weapon-type row + the non-weapon-kind row. A differing pick
    /// resets the item ("New <Kind>", zeroed stats) — the pick handler's
    /// job; the rows just render + carry payloads.
    item_type_rows: void,
};

/// A section's display label.
fn editorInspectorSectionLabel(section: types.EditorInspectorSectionId) []const u8 {
    return switch (section) {
        .identity => "Identity",
        .stats => "Stats",
        .weapons => "Weapons",
        .gear => "Gear",
        .utility_skills => "Utility skills",
        .inventory => "Inventory",
        .player => "Player",
        .footprint => "Footprint",
        .layers => "Layers",
        .item => "Item",
        .mission => "Mission",
        .current_level => "Current level",
    };
}

/// Row units an entry occupies: a section header is one; everything else
/// is two (the label line above the control line).
fn editorInspectorEntryUnits(entry: EditorInspectorEntry) i32 {
    return switch (entry) {
        .section, .spacer => 1,
        .field,
        .weapon_slot,
        .gear_slot,
        .utility_skill_row,
        .player_name_line,
        .import_player,
        .inventory_item_button,
        .entity_layer,
        .entity_layer_color,
        .add_entity_layer,
        .decoration_layer,
        .decoration_layer_color,
        .add_decoration_layer,
        => 2,
        // The type-pick rows: label line + TWO control rows.
        .item_type_rows => 3,
        // The type-pick rows' inventory mirror.
        .inventory_item_type_rows => 3,
        // A slot row: one 128px line of six cells.
        .inventory_slot_row => 1,
    };
}

/// The stat fields an item kind carries, in display order (the inspector
/// only offers these — a stat the item doesn't have commits nothing by
/// construction).
fn gearSlotStatSet(slot: types.GearSlot) []const types.ItemStatField {
    return switch (slot) {
        .main_hand, .off_hand => &.{.weapon_damage},
        .amulet => &.{.spell_damage},
        .coat => &.{ .health_bonus, .defense_bonus },
        .gloves => &.{ .damage_bonus, .health_bonus },
        .pants => &.{ .pickup_radius_bonus, .health_bonus },
        .boots => &.{ .speed_bonus, .health_bonus },
    };
}

fn itemStatLabel(stat: types.ItemStatField) []const u8 {
    // Lowercase-first: the label always follows its slot's name ("Coat
    // health bonus"), never standalone.
    return switch (stat) {
        .weapon_damage => "damage",
        .spell_damage => "spell damage",
        .health_bonus => "health bonus",
        .defense_bonus => "defense bonus",
        .damage_bonus => "damage bonus",
        .pickup_radius_bonus => "pickup radius",
        .speed_bonus => "speed bonus",
    };
}

/// The item content's standalone stat label (capitalized first letter —
/// the enemy content's "Max health" convention).
fn itemStatFieldLabel(stat: types.ItemStatField) []const u8 {
    return switch (stat) {
        .weapon_damage => "Damage",
        .spell_damage => "Spell damage",
        .health_bonus => "Health bonus",
        .defense_bonus => "Defense bonus",
        .damage_bonus => "Damage bonus",
        .pickup_radius_bonus => "Pickup radius",
        .speed_bonus => "Speed bonus",
    };
}

/// One gear slot's entries: the slot row + the equipped item's Name +
/// stat field rows (nothing extra while the slot is empty).
fn appendInspectorSlotEntries(
    allocator: std.mem.Allocator,
    template: types.Entity,
    entries: *std.ArrayList(EditorInspectorEntry),
    slot_row: EditorInspectorEntry,
    slot: types.GearSlot,
) !void {
    try entries.append(allocator, slot_row);
    if (template.gearSlotItem(slot) == null) return;
    const slot_label = types.gearSlotLabel(slot);
    try entries.append(allocator, .{ .field = .{
        .label = try std.fmt.allocPrint(allocator, "{s} name", .{slot_label}),
        .control = .{ .text = .{ .item_name = slot } },
    } });
    for (gearSlotStatSet(slot)) |stat| {
        try entries.append(allocator, .{ .field = .{
            .label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ slot_label, itemStatLabel(stat) }),
            .control = .{ .text = .{ .item_stat = .{ .slot = slot, .stat = stat } } },
        } });
    }
}

/// The Weapons + Gear sections (shared by the enemy + player content):
/// each section header, then (while expanded) each slot's row followed by
/// the equipped item's fields. The spacer BEFORE Weapons is the caller's —
/// it belongs to the caller's preceding section (Stats for the enemy
/// content, Player for the player content) and is emitted only while THAT
/// section is expanded.
fn appendInspectorGearSections(
    allocator: std.mem.Allocator,
    template: types.Entity,
    entries: *std.ArrayList(EditorInspectorEntry),
    expanded: *const [editor_inspector_section_count]bool,
) !void {
    try entries.append(allocator, .{ .section = .weapons });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.weapons)]) {
        for ([_]types.GearSlot{ .main_hand, .off_hand }) |hand| {
            try appendInspectorSlotEntries(allocator, template, entries, .{ .weapon_slot = hand }, hand);
        }
    }
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.weapons)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .gear });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.gear)]) {
        for ([_]types.GearSlot{ .amulet, .coat, .gloves, .pants, .boots }) |slot| {
            try appendInspectorSlotEntries(allocator, template, entries, .{ .gear_slot = slot }, slot);
        }
    }
}

/// The enemy-type inspector's content plan: five sections over every
/// field `parseEntityDefinition` reads (the coupling contract — anything
/// editable by text-editing the level file is a row here). Each section
/// header is followed by its children WHILE EXPANDED (collapsed sections
/// carry the header only — see `UiState.editor_inspector_section_expanded`).
/// The Weapons + Gear sections are state-dependent: each slot row is
/// followed by the equipped item's Name + stat rows (nothing when the slot
/// is empty).
fn editorInspectorEntityEntries(
    allocator: std.mem.Allocator,
    template: types.Entity,
    expanded: *const [editor_inspector_section_count]bool,
) ![]const EditorInspectorEntry {
    var entries: std.ArrayList(EditorInspectorEntry) = .empty;

    // Identity + Stats: fixed.
    try entries.append(allocator, .{ .section = .identity });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.identity)]) {
        try entries.appendSlice(allocator, &.{
            .{ .field = .{ .label = "Name", .control = .{ .text = .entity_name } } },
            .{ .field = .{ .label = "Sprite", .control = .sprite_button } },
            .{ .field = .{ .label = "Color", .control = .swatches } },
            .{ .field = .{ .label = "Displays weapons", .control = .toggle } },
        });
        // The section-break spacer belongs to the section ABOVE it — a
        // collapsed section takes no gap after it (headers stack flush).
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .stats });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.stats)]) {
        try entries.appendSlice(allocator, &.{
            .{ .field = .{ .label = "Max health", .control = .{ .text = .{ .entity_stat = .max_health } } } },
            .{ .field = .{ .label = "Defense", .control = .{ .text = .{ .entity_stat = .defense } } } },
            .{ .field = .{ .label = "Speed", .control = .{ .text = .{ .entity_stat = .speed } } } },
            .{ .field = .{ .label = "Aggro range", .control = .{ .text = .{ .entity_stat = .aggro_range } } } },
        });
        try entries.append(allocator, .spacer);
    }

    try appendInspectorGearSections(allocator, template, &entries, expanded);

    // Utility skills: ONE row of five skill slots (the entity-inspect
    // look), each slot opening the centered picker.
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.gear)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .utility_skills });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.utility_skills)]) {
        try entries.append(allocator, .{ .utility_skill_row = {} });
    }

    // Layers: per layer a slot row (sprite re-pick + delete) + a color
    // row, then the add button. The LAST section — the spacer above it
    // belongs to utility_skills.
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.utility_skills)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .layers });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.layers)]) {
        for (0..template.layers.len) |layer_index| {
            try entries.appendSlice(allocator, &.{
                .{ .entity_layer = @intCast(layer_index) },
                .{ .entity_layer_color = @intCast(layer_index) },
            });
        }
        try entries.append(allocator, .{ .add_entity_layer = {} });
    }

    return entries.items;
}

/// The PLAYER content's entries (the fallback target — the '!' spawn's
/// loadout): the loadout header + (while expanded) the read-only name line
/// + import button, the shared Weapons / Gear / Utility sections, and the
/// inventory SLOT GRID (16 rows of six cells). While a slot is selected,
/// its detail entries insert directly BELOW its slot row — the first
/// in-section expansion in the inspector (the entries list is rebuilt per
/// frame, so the insert is a conditional append): the Add/Delete row
/// first, then — only while an item exists (author decision: no type
/// rows while empty) — the type-pick rows + name + stats, mirroring the
/// item tool inspector exactly. No Identity / Stats sections — base
/// stats are enemy-authorable only; the player template keeps its
/// defaults.
fn editorInspectorPlayerEntries(
    allocator: std.mem.Allocator,
    template: types.Entity,
    expanded: *const [editor_inspector_section_count]bool,
    selected_slot: ?u32,
) ![]const EditorInspectorEntry {
    var entries: std.ArrayList(EditorInspectorEntry) = .empty;

    try entries.append(allocator, .{ .section = .player });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.player)]) {
        try entries.appendSlice(allocator, &.{
            .{ .player_name_line = {} },
            .{ .import_player = {} },
        });
        // The section-break spacer belongs to the section ABOVE it — a
        // collapsed section takes no gap after it (headers stack flush).
        try entries.append(allocator, .spacer);
    }
    try appendInspectorGearSections(allocator, template, &entries, expanded);

    if (expanded[@intFromEnum(types.EditorInspectorSectionId.gear)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .utility_skills });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.utility_skills)]) {
        try entries.append(allocator, .{ .utility_skill_row = {} });
    }

    if (expanded[@intFromEnum(types.EditorInspectorSectionId.utility_skills)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .inventory });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.inventory)]) {
        const selected = if (selected_slot) |slot| blk: {
            if (slot >= types.inventory_slot_count) break :blk null;
            break :blk slot;
        } else null;
        for (0..editor_inventory_row_count) |row| {
            try entries.append(allocator, .{ .inventory_slot_row = @intCast(row) });
            if (selected == null) continue;
            if (selected.? / editor_inventory_slots_per_row != row) continue;
            // The detail block — directly below the selected slot's row.
            try entries.append(allocator, .{ .inventory_item_button = selected.? });
            const item = template.inventory.slots[selected.?] orelse continue;
            try entries.append(allocator, .{ .inventory_item_type_rows = {} });
            // A skill tome has no name (it IS its skill) — no name row,
            // and itemStatSet yields no stats for it either.
            if (std.meta.activeTag(item) != .skill_tome) {
                try entries.append(allocator, .{ .field = .{
                    .label = "Name",
                    .control = .{ .inventory_item_text = .inventory_item_name },
                } });
            }
            for (types.itemStatSet(item)) |stat| {
                try entries.append(allocator, .{ .field = .{
                    .label = itemStatFieldLabel(stat),
                    .control = .{ .inventory_item_text = .{ .inventory_item_stat = stat } },
                } });
            }
        }
    }

    return entries.items;
}

/// The DECORATION content's entries: Identity (sprite + color — a
/// decoration's name IS its sprite path, so there is no name row) +
/// Footprint (a read-only tile count; the footprint editor is a later
/// slice). Decoration layers are deferred with the layer editor (they
/// arrive whole via a registry prefab pick in the meantime).
fn editorInspectorDecorationEntries(
    allocator: std.mem.Allocator,
    definition: types.DecorationTypeDef,
    expanded: *const [editor_inspector_section_count]bool,
) ![]const EditorInspectorEntry {
    var entries: std.ArrayList(EditorInspectorEntry) = .empty;

    try entries.append(allocator, .{ .section = .identity });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.identity)]) {
        try entries.appendSlice(allocator, &.{
            .{ .field = .{ .label = "Sprite", .control = .decoration_sprite_button } },
            .{ .field = .{ .label = "Color", .control = .decoration_swatches } },
        });
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .footprint });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.footprint)]) {
        try entries.appendSlice(allocator, &.{
            .{ .field = .{ .label = "Footprint", .control = .footprint_button } },
        });
        try entries.append(allocator, .spacer);
    }

    // Layers: per layer a slot row (sprite re-pick + delete) + a color
    // row, then the add button. The LAST section — the spacer above it
    // belongs to footprint.
    try entries.append(allocator, .{ .section = .layers });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.layers)]) {
        for (0..definition.layers.len) |layer_index| {
            try entries.appendSlice(allocator, &.{
                .{ .decoration_layer = @intCast(layer_index) },
                .{ .decoration_layer_color = @intCast(layer_index) },
            });
        }
        try entries.append(allocator, .{ .add_decoration_layer = {} });
    }

    return entries.items;
}

/// The ITEM content's entries (the Items palette group's target): one
/// collapsible section — the type-pick rows (weapon types + non-weapon
/// kinds; a differing pick resets the item), then the name field + one
/// numeric field per stat the kind carries. Skill tomes carry neither a
/// name nor stats (and are never offered by the pick rows — not
/// level-authorable); a tome in the palette is unreachable in practice
/// (buildEditorMission can't produce one) and renders bare rows here.
fn editorInspectorItemEntries(
    allocator: std.mem.Allocator,
    item: types.Item,
    expanded: *const [editor_inspector_section_count]bool,
) ![]const EditorInspectorEntry {
    var entries: std.ArrayList(EditorInspectorEntry) = .empty;

    try entries.append(allocator, .{ .section = .item });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.item)]) {
        try entries.append(allocator, .{ .item_type_rows = {} });
        // A skill tome has no name (it IS its skill) — no name row.
        if (std.meta.activeTag(item) != .skill_tome) {
            try entries.append(allocator, .{ .field = .{
                .label = "Name",
                .control = .{ .item_text = .item_def_name },
            } });
        }
        for (types.itemStatSet(item)) |stat| {
            try entries.append(allocator, .{ .field = .{
                .label = itemStatFieldLabel(stat),
                .control = .{ .item_text = .{ .item_def_stat = stat } },
            } });
        }
    }

    return entries.items;
}

/// Build the inspector's content inside the open panel (called by
/// `buildEditorInspectorPanel`): the resolved target's entries — the
/// active enemy tool's field rows, or the player loadout (the fallback
/// target). View-relative windowed emission
/// (the skills-panel model): only FULLY visible rows are emitted at the top
/// of the content region, so nothing half-draws or overflows the panel; the
/// scrollbar thumb conveys the position. `scroll_offset` (rows) is clamped
/// here — authoritative, this fn knows the content height. The wheel
/// routes here from handleAnytimeInput when the pointer is inside the panel
/// rect; while a text field is focused the wheel still flows (only key
/// bindings are suppressed).
/// A section-header strip: panel-backed, the label left-padded and
/// vertically centered (the group-header visual class) — and the section's
/// EXPAND/COLLAPSE button: the whole strip is clickable, the +/- marker
/// prefix carries the state.
fn emitInspectorSectionStrip(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    section: types.EditorInspectorSectionId,
    expanded: bool,
    strip_color: types.Color,
    active_theme: types.ActiveColorTheme,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = strip_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = .toggle_editor_inspector_section,
        .editor_section = section,
        .tooltip = .{ .header = try spanRow(allocator, text(
            if (expanded) "Collapse" else "Expand",
        )) },
    } });
    const label = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ if (expanded) "- " else "+ ", editorInspectorSectionLabel(section) },
    );
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = .{
            .x = cell.x + ui_gap,
            .y = cell.y + @divFloor(cell.height - editor_group_header_font_size, 2),
        },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// The entity template an inspector content path edits, resolved from
/// the inspector target (enemy type vs player loadout): the template its
/// controls read, the `EntityEditTarget` its commits carry (text-field
/// refs), and the team gradient its controls tint with (enemy content =
/// enemy gradient, player content = player gradient — matching the
/// entity-inspect panel's team-gradient coloring).
const InspectorEntityContext = struct {
    template: types.Entity,
    edit_target: types.EntityEditTarget,
    gradient_colors: [types.gradient_color_count]types.Color,
};

/// The decoration type an inspector content path edits, resolved from
/// the inspector target: the definition its controls read. Coloring is
/// the WORLD gradient (decorations index into it, matching the in-game
/// tinting) — carried by the active theme, not this struct.
const InspectorDecorationContext = struct {
    type_definition: types.DecorationTypeDef,
};

/// The palette item type an inspector content path edits, resolved from
/// the inspector target: the ItemTypeDef its controls read. Carries the
/// palette index (the text-field refs' `.item_type` target). Coloring is
/// the PLAYER gradient (matching the Items palette group's tinting).
const InspectorItemContext = struct {
    type_id: u32,
    type_definition: types.ItemTypeDef,
};

fn buildEditorInspectorContent(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    ui_state: *UiState,
) !void {
    const panel = editorInspectorPanelRect();
    const content: Rectangle = .{
        .x = panel.x + ui_gap,
        .y = panel.y + ui_gap,
        .width = panel.width - 2 * ui_gap,
        .height = panel.height - 2 * ui_gap,
    };
    const visible_rows = @divFloor(content.height, editor_inspector_row_height);
    const scroll_offset = &ui_state.editor_inspector_scroll;

    // Target resolution: the active enemy/decoration tool, a selection of
    // placements that all reference one type, or the PLAYER fallback (the
    // '!' spawn's loadout) — see editorInspectorTarget. All paths share
    // the windowing machinery below; they differ in entries + context.
    // Exactly one context is populated (the one its entries read).
    const target = editorInspectorTarget(editor);
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
    const item_context: ?InspectorItemContext = switch (target) {
        .item_type => |index| .{
            .type_id = index,
            .type_definition = editor.item_types[index],
        },
        .entity_type, .player, .decoration_type => null,
    };
    const entries: []const EditorInspectorEntry = switch (target) {
        .entity_type => |index| try editorInspectorEntityEntries(
            allocator,
            editor.entity_types[index].template,
            &ui_state.editor_inspector_section_expanded,
        ),
        .player => try editorInspectorPlayerEntries(
            allocator,
            editor.player_def.template,
            &ui_state.editor_inspector_section_expanded,
            ui_state.editor_inventory_selected_slot,
        ),
        .decoration_type => |index| try editorInspectorDecorationEntries(
            allocator,
            editor.decoration_types[index],
            &ui_state.editor_inspector_section_expanded,
        ),
        .item_type => |index| try editorInspectorItemEntries(
            allocator,
            editor.item_types[index].item,
            &ui_state.editor_inspector_section_expanded,
        ),
    };
    // Unit math: a section header is 1 row unit, a field entry 2 (label
    // line + control line). Scroll + windowing are in units, so every line
    // stays on the 128px grid at any offset.
    var total_units: i32 = 0;
    for (entries) |entry| total_units += editorInspectorEntryUnits(entry);
    const max_scroll_row = @max(@as(i32, 0), total_units - visible_rows);
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;

    // Team gradient throughout — the context's gradient (enemy content
    // enemy, player content player; matching the entity-inspect panel's
    // team-gradient coloring). Decoration content tints with the WORLD
    // gradient instead (the in-game decoration tinting) — one button
    // color, resolved per target (the section strips read it too). Item
    // content tints with the PLAYER gradient (matching the Items palette
    // group's tinting).
    const button_color: Color = switch (target) {
        .entity_type, .player => entity_context.?.gradient_colors[
            @min(@as(u32, 5), types.gradient_color_count - 1)
        ],
        .decoration_type => active_theme.world_gradient.colors[
            @min(@as(u32, 5), types.gradient_color_count - 1)
        ],
        .item_type => active_theme.player_gradient.colors[
            @min(@as(u32, 5), types.gradient_color_count - 1)
        ],
    };
    const text_edit: ?*const TextEditState =
        if (ui_state.text_edit != null) &ui_state.text_edit.? else null;

    // Windowed emission (the skills-panel model, variable-height entries):
    // an entry is emitted only when it FULLY fits the visible window —
    // partially-visible entries are skipped (nothing half-draws or
    // overflows the panel; the scrollbar thumb conveys the position).
    var start_unit: i32 = 0;
    var index: usize = 0;
    while (index < entries.len and start_unit < scroll_offset.* + visible_rows) : (index += 1) {
        const entry = entries[index];
        const units = editorInspectorEntryUnits(entry);
        defer start_unit += units;
        if (start_unit < scroll_offset.* or
            start_unit + units > scroll_offset.* + visible_rows) continue;
        const cell: Rectangle = .{
            .x = content.x,
            .y = content.y + (start_unit - scroll_offset.*) * editor_inspector_row_height,
            .width = content.width,
            .height = units * editor_inspector_row_height,
        };
        switch (entry) {
            // A blank unit — the section-break gap.
            .spacer => {},
            // Section header: a panel-backed strip (the group-header visual
            // class), label left-padded + vertically centered.
            .section => |section_id| try emitInspectorSectionStrip(
                elements,
                allocator,
                cell,
                section_id,
                ui_state.editor_inspector_section_expanded[@intFromEnum(section_id)],
                button_color,
                active_theme,
            ),
            // Field entry (two lines): the label line on top, the editable
            // value below it — full content width, one thing per line.
            .field => |row| {
                try elements.append(allocator, .{ .text_label = .{
                    .text = row.label,
                    .screen_position = .{ .x = cell.x, .y = inspectorLabelY(cell) },
                    .font_size = editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
                const control_rect = inspectorControlRect(cell);
                switch (row.control) {
                    .none => {},
                    .sprite_button => try emitInspectorSpriteButton(
                        elements,
                        allocator,
                        font_metrics,
                        entity_context.?.template.sprite,
                        button_color,
                        control_rect,
                        active_theme,
                    ),
                    // The decoration content's sprite row — same emitter,
                    // decoration context (a decoration's sprite id is its
                    // bare stem or `custom/<mission>/<stem>`).
                    .decoration_sprite_button => try emitInspectorSpriteButton(
                        elements,
                        allocator,
                        font_metrics,
                        decoration_context.?.type_definition.sprite,
                        button_color,
                        control_rect,
                        active_theme,
                    ),
                    .text => |field_id| try emitInspectorTextField(
                        elements,
                        allocator,
                        font_metrics,
                        text_edit,
                        entity_context.?,
                        control_rect,
                        field_id,
                        active_theme,
                    ),
                    // A palette item TYPE's field (name / stat) — the same
                    // element, reading the item context (the `.item_type`
                    // ref target).
                    .item_text => |field_id| try emitInspectorItemTextField(
                        elements,
                        allocator,
                        font_metrics,
                        text_edit,
                        item_context.?,
                        control_rect,
                        field_id,
                        active_theme,
                    ),
                    // An inventory slot item's field (name / stat) — the
                    // same element over the selected slot's item (the
                    // `.inventory_slot` ref target; the entries only
                    // exist while the slot is selected + occupied, so
                    // the unwraps can't fail on a live frame).
                    .inventory_item_text => |field_id| {
                        const selected = ui_state.editor_inventory_selected_slot orelse continue;
                        const item = entity_context.?.template.inventory.slots[selected] orelse continue;
                        try emitInspectorInventoryItemTextField(
                            elements,
                            allocator,
                            font_metrics,
                            text_edit,
                            item,
                            selected,
                            control_rect,
                            field_id,
                            active_theme,
                        );
                    },
                    .swatches => try emitInspectorColorSwatches(
                        elements,
                        allocator,
                        entity_context.?.gradient_colors,
                        entity_context.?.template.color_index,
                        .select_editor_entity_color,
                        null,
                        control_rect,
                    ),
                    // The decoration content's swatch row — the WORLD
                    // gradient + the decoration commit action.
                    .decoration_swatches => try emitInspectorColorSwatches(
                        elements,
                        allocator,
                        active_theme.world_gradient.colors,
                        decoration_context.?.type_definition.color_index,
                        .select_editor_decoration_color,
                        null,
                        control_rect,
                    ),
                    // The decoration content's footprint row: a button
                    // showing the tile count that opens the footprint
                    // editor.
                    .footprint_button => {
                        const tile_count = try std.fmt.allocPrint(
                            allocator,
                            "{d} tiles",
                            .{decoration_context.?.type_definition.footprint.len},
                        );
                        try emitInspectorFootprintButton(
                            elements,
                            allocator,
                            font_metrics,
                            tile_count,
                            button_color,
                            control_rect,
                            active_theme,
                        );
                    },
                    .toggle => try emitInspectorToggle(
                        elements,
                        allocator,
                        font_metrics,
                        entity_context.?,
                        control_rect,
                        active_theme,
                    ),
                }
            },
            // A weapon slot: the slot's label + the weapon-type row (create
            // on pick while empty / retype in place) + Delete while equipped.
            .weapon_slot => |hand| {
                try emitInspectorSlotLabel(elements, allocator, cell, types.gearSlotLabel(hand), active_theme);
                const control_rect = inspectorControlRect(cell);
                try emitInspectorWeaponSlot(
                    elements,
                    allocator,
                    font_metrics,
                    entity_context.?,
                    hand,
                    control_rect,
                    active_theme,
                );
            },
            // The utility-skill bar: the label line + one row of five
            // 128×128 skill slots — the entity-inspect look (skill-button
            // frame + icon, the empty diamond), each opening the picker.
            .utility_skill_row => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Skill bar", active_theme);
                const slot_row: Rectangle = .{
                    .x = cell.x,
                    .y = cell.y + editor_inspector_row_height,
                    .width = cell.width,
                    .height = editor_inspector_row_height,
                };
                try emitInspectorUtilitySkillRow(
                    elements,
                    allocator,
                    entity_context.?,
                    slot_row,
                );
            },
            // A gear slot: the slot's label + Add (while empty) / Delete
            // (while equipped); the item's field entries follow as their
            // own rows.
            .gear_slot => |slot| {
                try emitInspectorSlotLabel(elements, allocator, cell, types.gearSlotLabel(slot), active_theme);
                const control_rect = inspectorControlRect(cell);
                try emitInspectorGearSlot(
                    elements,
                    allocator,
                    font_metrics,
                    entity_context.?,
                    slot,
                    control_rect,
                    active_theme,
                );
            },
            // The player loadout's name — a read-only value line (the
            // name arrives with the imported player data).
            .player_name_line => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Name", active_theme);
                try elements.append(allocator, .{ .text_label = .{
                    .text = entity_context.?.template.name,
                    .screen_position = .{
                        .x = cell.x,
                        .y = cell.y + editor_inspector_row_height,
                    },
                    .font_size = editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
            },
            // The Import button: copy the session's player data (or the
            // new-game default, with none) into the loadout.
            // The Import row: TWO half-width buttons — Player data (the
            // session's data, or the new-game default with none) and Max
            // player (the shipped data/max_player.txt loadout — the
            // author-times tool for official missions).
            .import_player => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Import", active_theme);
                const control_rect = inspectorControlRect(cell);
                const import_button_color = entity_context.?.gradient_colors[
                    @min(@as(u32, 5), types.gradient_color_count - 1)
                ];
                const button_width = @divFloor(control_rect.width - ui_gap, 2);
                try emitInspectorImportButton(
                    elements,
                    allocator,
                    font_metrics,
                    .{ .x = control_rect.x, .y = control_rect.y, .width = button_width, .height = control_rect.height },
                    "Player data",
                    .import_editor_player,
                    import_button_color,
                    active_theme.lightest,
                );
                try emitInspectorImportButton(
                    elements,
                    allocator,
                    font_metrics,
                    .{
                        .x = control_rect.x + button_width + ui_gap,
                        .y = control_rect.y,
                        .width = button_width,
                        .height = control_rect.height,
                    },
                    "Max player",
                    .import_editor_max_player,
                    import_button_color,
                    active_theme.lightest,
                );
            },
            // One row of the inventory slot grid: six square cells
            // (occupied = item icon overlay, the type-cell visual class;
            // the selected cell carries the edge highlight). Clicking a
            // cell selects the slot — the detail entries below are the
            // per-frame insert.
            .inventory_slot_row => |row_index| {
                try emitInspectorInventorySlotRow(
                    elements,
                    allocator,
                    entity_context.?,
                    row_index,
                    cell,
                    ui_state.editor_inventory_selected_slot,
                );
            },
            // The selected slot's Add/Delete row (the FIRST detail
            // entry below its slot row): the "Slot N" label line + the
            // half-width button — Add while the slot is empty, Delete
            // while an item is present.
            .inventory_item_button => |slot_index| {
                const label = try std.fmt.allocPrint(allocator, "Slot {d}", .{slot_index + 1});
                try emitInspectorSlotLabel(elements, allocator, cell, label, active_theme);
                const control_rect = inspectorControlRect(cell);
                const occupied =
                    entity_context.?.template.inventory.slots[slot_index] != null;
                const button_label: []const u8 = if (occupied) "Delete" else "Add";
                const action: types.Action = if (occupied)
                    .delete_editor_inventory_item
                else
                    .add_editor_inventory_item;
                try emitInspectorInventoryItemButton(
                    elements,
                    allocator,
                    font_metrics,
                    control_rect,
                    button_label,
                    action,
                    slot_index,
                    entity_context.?.gradient_colors,
                    active_theme.lightest,
                );
            },
            // The selected slot's type-pick rows — the item tool
            // inspector's exact rows over the slot's item (reset-
            // everything picks; emitted only while occupied).
            .inventory_item_type_rows => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Type", active_theme);
                const weapon_row: Rectangle = .{
                    .x = cell.x,
                    .y = cell.y + editor_inspector_row_height,
                    .width = cell.width,
                    .height = editor_inspector_row_height,
                };
                const gear_row: Rectangle = .{
                    .x = cell.x,
                    .y = cell.y + 2 * editor_inspector_row_height,
                    .width = cell.width,
                    .height = editor_inspector_row_height,
                };
                const selected = ui_state.editor_inventory_selected_slot orelse continue;
                const item = entity_context.?.template.inventory.slots[selected] orelse continue;
                try emitInspectorItemTypeRows(
                    elements,
                    allocator,
                    item,
                    weapon_row,
                    gear_row,
                    active_theme,
                    .select_editor_inventory_item_type,
                );
            },
            // One ENEMY layer: the slot row — the sprite-stem button (a
            // re-pick opens the layer picker for this index) + Delete.
            .entity_layer => |layer_index| {
                try emitInspectorSlotLabel(
                    elements,
                    allocator,
                    cell,
                    try inspectorLayerLabel(allocator, layer_index, false),
                    active_theme,
                );
                const control_rect = inspectorControlRect(cell);
                try emitInspectorLayerRow(
                    elements,
                    allocator,
                    font_metrics,
                    entity_context.?.template.layers[layer_index].sprite,
                    layer_index,
                    .open_editor_entity_layer_picker,
                    .delete_editor_entity_layer,
                    button_color,
                    control_rect,
                    active_theme,
                );
            },
            // One enemy layer's color swatch row (the enemy gradient).
            .entity_layer_color => |layer_index| {
                try emitInspectorSlotLabel(
                    elements,
                    allocator,
                    cell,
                    try inspectorLayerLabel(allocator, layer_index, true),
                    active_theme,
                );
                const control_rect = inspectorControlRect(cell);
                try emitInspectorColorSwatches(
                    elements,
                    allocator,
                    entity_context.?.gradient_colors,
                    entity_context.?.template.layers[layer_index].color_index,
                    .select_editor_entity_layer_color,
                    layer_index,
                    control_rect,
                );
            },
            // The enemy content's add-layer row: a Pick-sprite button that
            // opens the layer picker in ADD mode (no layer payload).
            .add_entity_layer => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Add layer", active_theme);
                const control_rect = inspectorControlRect(cell);
                const rect: Rectangle = .{
                    .x = control_rect.x,
                    .y = control_rect.y,
                    .width = @divFloor(control_rect.width, 2),
                    .height = control_rect.height,
                };
                try emitInspectorLayerButton(
                    elements,
                    allocator,
                    font_metrics,
                    rect,
                    "Pick sprite",
                    .open_editor_entity_layer_picker,
                    null,
                    button_color,
                    active_theme.lightest,
                );
            },
            // One DECORATION layer — the entity arms' shape over the
            // decoration context (world gradient, decoration actions).
            .decoration_layer => |layer_index| {
                try emitInspectorSlotLabel(
                    elements,
                    allocator,
                    cell,
                    try inspectorLayerLabel(allocator, layer_index, false),
                    active_theme,
                );
                const control_rect = inspectorControlRect(cell);
                try emitInspectorLayerRow(
                    elements,
                    allocator,
                    font_metrics,
                    decoration_context.?.type_definition.layers[layer_index].sprite,
                    layer_index,
                    .open_editor_decoration_layer_picker,
                    .delete_editor_decoration_layer,
                    button_color,
                    control_rect,
                    active_theme,
                );
            },
            .decoration_layer_color => |layer_index| {
                try emitInspectorSlotLabel(
                    elements,
                    allocator,
                    cell,
                    try inspectorLayerLabel(allocator, layer_index, true),
                    active_theme,
                );
                const control_rect = inspectorControlRect(cell);
                try emitInspectorColorSwatches(
                    elements,
                    allocator,
                    active_theme.world_gradient.colors,
                    decoration_context.?.type_definition.layers[layer_index].color_index,
                    .select_editor_decoration_layer_color,
                    layer_index,
                    control_rect,
                );
            },
            .add_decoration_layer => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Add layer", active_theme);
                const control_rect = inspectorControlRect(cell);
                const rect: Rectangle = .{
                    .x = control_rect.x,
                    .y = control_rect.y,
                    .width = @divFloor(control_rect.width, 2),
                    .height = control_rect.height,
                };
                try emitInspectorLayerButton(
                    elements,
                    allocator,
                    font_metrics,
                    rect,
                    "Pick sprite",
                    .open_editor_decoration_layer_picker,
                    null,
                    button_color,
                    active_theme.lightest,
                );
            },
            // The item content's type-pick rows: the "Type" label line +
            // the weapon-type row + the non-weapon-kind row (a differing
            // pick resets the item — see emitInspectorItemTypeRows).
            .item_type_rows => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Type", active_theme);
                const weapon_row: Rectangle = .{
                    .x = cell.x,
                    .y = cell.y + editor_inspector_row_height,
                    .width = cell.width,
                    .height = editor_inspector_row_height,
                };
                const gear_row: Rectangle = .{
                    .x = cell.x,
                    .y = cell.y + 2 * editor_inspector_row_height,
                    .width = cell.width,
                    .height = editor_inspector_row_height,
                };
                try emitInspectorItemTypeRows(
                    elements,
                    allocator,
                    item_context.?.type_definition.item,
                    weapon_row,
                    gear_row,
                    active_theme,
                    .select_editor_item_type,
                );
            },
        }
    }

    // Scrollbar (only when the content overflows): track + proportional
    // thumb in the right `ui_gap` margin — the skills-panel geometry,
    // measured in row units.
    if (total_units > visible_rows) {
        const track_x = panel.x + panel.width - ui_gap +
            @divFloor(ui_gap - editor_inspector_scrollbar_width, 2);
        const track_y = content.y;
        const track_height = visible_rows * editor_inspector_row_height;
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = track_y },
            .width = editor_inspector_scrollbar_width,
            .height = track_height,
            .color = .{ .r = 80, .g = 80, .b = 80 },
        } });
        const thumb_height = @max(
            @as(i32, 40),
            @divTrunc(track_height * visible_rows, total_units),
        );
        const thumb_y = track_y +
            @divTrunc(scroll_offset.* * (track_height - thumb_height), max_scroll_row);
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = thumb_y },
            .width = editor_inspector_scrollbar_width,
            .height = thumb_height,
            .color = .{ .r = 180, .g = 180, .b = 180 },
        } });
    }
}

/// Emit one inspector text field in the row's control column. The builder
/// computes ALL render data (it owns the metrics + the focused buffer):
/// the display text is the live buffer while THIS field is focused, else
/// the field's current value; the caret/selection geometry is measured
/// from the buffer. Display text is duped into the frame allocator — an
/// element slice must never point into UiState (it mutates between
/// frames, and the previous frame's elements are hit-tested a frame
/// later).
/// The base-sprite row's control (entity + decoration content): a
/// half-width panel-backed button showing the current stem — clicking
/// opens the centered sprite picker (the input site routes entity vs
/// decoration by the inspector target).
fn emitInspectorSpriteButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    sprite: []const u8,
    button_color: Color,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = .open_editor_sprite_picker,
        .tooltip = .{ .header = try spanRow(allocator, text("Pick sprite")) },
    } });
    const label = if (sprite.len > 0) sprite else "(none)";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

fn emitInspectorTextField(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    text_edit: ?*const TextEditState,
    context: InspectorEntityContext,
    control_rect: Rectangle,
    field_id: types.TextFieldId,
    active_theme: types.ActiveColorTheme,
) !void {
    const value = context.template.textFieldValue(allocator, field_id) catch
        @panic("failed to format entity field value");
    try emitTextFieldUi(
        elements,
        allocator,
        font_metrics,
        text_edit,
        .{ .id = field_id, .target = .{ .entity = context.edit_target } },
        value,
        control_rect,
        active_theme,
    );
}

/// The inventory slot's text field (name / one stat): the item
/// content's exact shape over the selected slot's item — the slot index
/// rides the `.inventory_slot` ref target (the level-name pattern, so a
/// mid-edit selection change can't retarget the commit).
fn emitInspectorInventoryItemTextField(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    text_edit: ?*const TextEditState,
    item: types.Item,
    slot_index: u32,
    control_rect: Rectangle,
    field_id: types.TextFieldId,
    active_theme: types.ActiveColorTheme,
) !void {
    const value = types.itemTextFieldValue(item, allocator, field_id) catch
        @panic("failed to format item field value");
    try emitTextFieldUi(
        elements,
        allocator,
        font_metrics,
        text_edit,
        .{ .id = field_id, .target = .{ .inventory_slot = slot_index } },
        value,
        control_rect,
        active_theme,
    );
}

/// One row of the Inventory section's slot grid: six square cells, one
/// per slot (`ui/item_slot` button + item icon overlay while occupied —
/// the type-cell visual class). The selected cell carries the edge
/// highlight; every cell's click selects its slot.
fn emitInspectorInventorySlotRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    context: InspectorEntityContext,
    row_index: u32,
    cell: Rectangle,
    selected_slot: ?u32,
) !void {
    const player = context.gradient_colors;
    const button_color = player[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_icon_color = player[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const cell_size = editor_inspector_row_height;
    for (0..editor_inventory_slots_per_row) |column| {
        const slot_index: u32 = row_index * editor_inventory_slots_per_row + @as(u32, @intCast(column));
        const rect: Rectangle = .{
            .x = cell.x + @as(i32, @intCast(column)) * (cell_size + ui_gap),
            .y = cell.y,
            .width = cell_size,
            .height = cell_size,
        };
        const item = context.template.inventory.slots[slot_index];
        const tooltip = if (item) |some|
            Tooltip{ .header = try spanRow(allocator, text(types.itemName(some))) }
        else
            null;
        try elements.append(allocator, .{ .button = .{
            .sprite_id = "ui/item_slot",
            .screen_position = rect.position(),
            .width = rect.width,
            .height = rect.height,
            .action = .select_editor_inventory_slot,
            .editor_inventory_slot = slot_index,
            .color = button_color,
            .highlighted = selected_slot != null and selected_slot.? == slot_index,
            .tooltip = tooltip,
        } });
        if (item) |some| {
            const fitted = scaleToFit(rect, inventory_slot_size, inventory_slot_size);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = itemIconSpriteId(some),
                .screen_position = fitted.position(),
                .width = fitted.width,
                .height = fitted.height,
                .color = item_icon_color,
                .blocks_input = false,
            } });
        }
    }
}

/// One of the player content's Import buttons (Player data / Max
/// player): panel-backed spriteless button + centered label — the
/// slot-button visual class.
fn emitInspectorImportButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    rect: Rectangle,
    label: []const u8,
    action: types.Action,
    button_color: Color,
    label_color: Color,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = action,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = label_color,
        .blocks_input = false,
    } });
}

/// The selected inventory slot's Add/Delete button: the
/// `emitInspectorSlotButton` shape with the slot-index payload instead of
/// a gear slot.
fn emitInspectorInventoryItemButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    control_rect: Rectangle,
    label: []const u8,
    action: types.Action,
    slot_index: u32,
    gradient_colors: [types.gradient_color_count]Color,
    label_color: Color,
) !void {
    const button_color = gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    // Half the panel width — full-width reads as a section header.
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = action,
        .editor_inventory_slot = slot_index,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = label_color,
        .blocks_input = false,
    } });
}

/// The item content's text field (name / one stat): the entity field's
/// exact shape over the item context — `itemTextFieldValue` is the value
/// source, `.item_type` the ref target.
fn emitInspectorItemTextField(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    text_edit: ?*const TextEditState,
    context: InspectorItemContext,
    control_rect: Rectangle,
    field_id: types.TextFieldId,
    active_theme: types.ActiveColorTheme,
) !void {
    const value = types.itemTextFieldValue(context.type_definition.item, allocator, field_id) catch
        @panic("failed to format item field value");
    try emitTextFieldUi(
        elements,
        allocator,
        font_metrics,
        text_edit,
        .{ .id = field_id, .target = .{ .item_type = context.type_id } },
        value,
        control_rect,
        active_theme,
    );
}

/// The text-field ELEMENT (shared by the inspector's entity fields and
/// the metadata sidebar's name fields): the paper-strip visual (lightest
/// frame, pure-black text — the contrast is the point; the caret +
/// selection draw in the same color, see the backend arm) + the focused
/// field's live buffer/caret/selection overlay.
fn emitTextFieldUi(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    text_edit: ?*const TextEditState,
    ref: types.TextFieldRef,
    current_value: []const u8,
    field_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const font_size = editor_group_header_font_size;
    var field: TextFieldUi = .{
        .screen_position = field_rect.position(),
        .width = field_rect.width,
        .height = field_rect.height,
        .text_position = .{
            .x = field_rect.x + ui_gap,
            .y = field_rect.y + @divFloor(field_rect.height - font_size, 2),
        },
        .text = try allocator.dupe(u8, current_value),
        .font_size = font_size,
        .frame_color = active_theme.lightest,
        .text_color = .{ .r = 0, .g = 0, .b = 0 },
        .ref = ref,
    };

    if (text_edit) |edit| {
        if (std.meta.eql(edit.field, ref)) {
            const buffer_text = edit.buffer.currentText();
            field.text = try allocator.dupe(u8, buffer_text);
            if (edit.buffer.selectionRange()) |selection| {
                const before = font_metrics.measureSpanWidth(text(buffer_text[0..selection.start]), font_size);
                const within = font_metrics.measureSpanWidth(text(buffer_text[selection.start..selection.end]), font_size);
                field.selection = .{ .x = before, .width = within };
            }
            const caret_x = font_metrics.measureSpanWidth(text(buffer_text[0..edit.buffer.caret]), font_size);
            field.caret = .{ .x = caret_x, .height = font_size };
        }
    }

    try elements.append(allocator, .{ .text_field = field });
}

/// The color_index control (base + layer rows, entity + decoration
/// content): one swatch per gradient index (the settings screen's
/// player-color row is the precedent — colored fill + invisible payload
/// button + highlighted selection). The gradient source + commit action
/// differ per content kind (enemy / player team gradient via
/// `.select_editor_entity_color`, world gradient via
/// `.select_editor_decoration_color`; the `_layer_color` actions for layer
/// rows, with `layer_index` riding the payload). A swatch click commits
/// the index (same-value picks never fire).
fn emitInspectorColorSwatches(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    gradient: [types.gradient_color_count]types.Color,
    current_index: u32,
    action: types.Action,
    layer_index: ?u32,
    control_rect: Rectangle,
) !void {
    for (0..types.gradient_color_count) |index| {
        const swatch_rect: Rectangle = .{
            .x = control_rect.x + @as(i32, @intCast(index)) * (control_rect.height + ui_gap),
            .y = control_rect.y,
            .width = control_rect.height,
            .height = control_rect.height,
        };
        // The swatch fill.
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = swatch_rect.position(),
            .width = swatch_rect.width,
            .height = swatch_rect.height,
            .color = gradient[@min(@as(u32, @intCast(index)), types.gradient_color_count - 1)],
        } });
        // Invisible hit-test button over it, carrying the index (+ the
        // layer index on a layer row).
        try elements.append(allocator, .{ .button = .{
            .screen_position = swatch_rect.position(),
            .width = swatch_rect.width,
            .height = swatch_rect.height,
            .action = action,
            .editor_color = @intCast(index),
            .editor_layer = layer_index,
            .highlighted = current_index == index,
        } });
    }
}

/// The displays_weapons control: a panel-backed strip showing the current
/// value in the FORMAT's vocabulary ("true"/"false" — the exact tokens
/// `asBool` parses), highlighted while true; clicking flips it via
/// `.toggle_editor_entity_displays_weapons`.
fn emitInspectorToggle(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    context: InspectorEntityContext,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const current = context.template.displays_weapons;
    const button_color = context.gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const label: []const u8 = if (current) "true" else "false";
    // Half the panel width — full-width reads as a section header; the
    // value vocabulary ("true"/"false") carries the state, no highlight.
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = .toggle_editor_entity_displays_weapons,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// A slot entry's label line (the top row unit of a weapon/gear slot).
fn emitInspectorSlotLabel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    label: []const u8,
    active_theme: types.ActiveColorTheme,
) !void {
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = .{ .x = cell.x, .y = inspectorLabelY(cell) },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// A weapon slot's control line: the six weapon types as cells (the
/// enemy_<type> silhouette the entity will actually wield, on the shared
/// button background — the palette tool-cell visual class). Picking a type
/// CREATES a default weapon while the slot is empty, or RETYPES in place
/// (name/damage kept); the current type is highlighted. A Delete button
/// follows while a weapon is equipped (clears the slot to null).
fn emitInspectorWeaponSlot(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    context: InspectorEntityContext,
    hand: types.GearSlot,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const button_color = context.gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_icon_color = context.gradient_colors[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const equipped_weapon: ?types.Weapon = switch (hand) {
        .main_hand => context.template.main_hand_weapon,
        .off_hand => context.template.off_hand_weapon,
        else => null,
    };

    const cell_size = control_rect.height;
    const cell_pitch = cell_size + ui_gap;
    inline for (std.meta.fields(types.WeaponType), 0..) |field, loop_index| {
        const weapon_type: types.WeaponType = @enumFromInt(field.value);
        const index: i32 = @intCast(loop_index);
        const cell: Rectangle = .{
            .x = control_rect.x + index * cell_pitch,
            .y = control_rect.y,
            .width = cell_size,
            .height = cell_size,
        };
        const highlighted = if (equipped_weapon) |weapon| weapon.weapon_type == weapon_type else false;
        try elements.append(allocator, .{ .button = .{
            .sprite_id = "ui/item_slot",
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .action = .select_editor_weapon_type,
            .editor_gear_slot = hand,
            .editor_weapon_type = weapon_type,
            .color = button_color,
            .highlighted = highlighted,
            .tooltip = .{ .header = try spanRow(allocator, text(types.weaponTypeLabel(weapon_type))) },
        } });
        // The item icon (the inventory's `items/<type>` art — the author
        // picks an ITEM, not an entity overlay), palette item-icon tint.
        const sprite_id = try std.fmt.allocPrint(
            allocator,
            "items/{s}",
            .{field.name},
        );
        const fitted = scaleToFit(cell, inventory_slot_size, inventory_slot_size);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = sprite_id,
            .screen_position = fitted.position(),
            .width = fitted.width,
            .height = fitted.height,
            .color = item_icon_color,
            .blocks_input = false,
        } });
    }

    // Delete (while equipped): the row's remaining width after the cells.
    if (equipped_weapon != null) {
        const type_row_width = @as(i32, @intCast(std.meta.fields(types.WeaponType).len)) * cell_pitch - ui_gap;
        const delete_rect: Rectangle = .{
            .x = control_rect.x + type_row_width + ui_gap,
            .y = control_rect.y,
            .width = control_rect.width - type_row_width - 2 * ui_gap,
            .height = cell_size,
        };
        try emitInspectorSlotButton(
            elements,
            allocator,
            font_metrics,
            delete_rect,
            "Delete",
            .delete_editor_item,
            hand,
            button_color,
            active_theme.lightest,
        );
    }
}

/// The item content's type-pick rows: the six weapon types on the first
/// row, the five non-weapon kinds on the second (skill tomes excluded —
/// not authorable as ground items). The weapon-slot cells' visual class
/// (`ui/item_slot` button + the `items/<type>` icon, palette tinting).
/// Any pick that DIFFERS from the current item resets it to a
/// "New <Kind>" default with zeroed stats (author decision — no
/// retype-keeps-identity case; the input handler owns that policy); an
/// identical pick is a no-op. The current type/kind is highlighted.
fn emitInspectorItemTypeRows(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    item: types.Item,
    weapon_row: Rectangle,
    gear_row: Rectangle,
    active_theme: types.ActiveColorTheme,
    action: types.Action,
) !void {
    const player = active_theme.player_gradient.colors;
    const button_color = player[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_icon_color = player[@min(@as(u32, 1), types.gradient_color_count - 1)];

    // Row 1: the weapon types (highlighted while the item is a weapon of
    // that type).
    inline for (std.meta.fields(types.WeaponType), 0..) |field, loop_index| {
        const weapon_type: types.WeaponType = @enumFromInt(field.value);
        const highlighted = switch (item) {
            .weapon => |weapon| weapon.weapon_type == weapon_type,
            else => false,
        };
        try emitInspectorItemTypeCell(
            elements,
            allocator,
            weapon_row,
            @intCast(loop_index),
            .weapon,
            weapon_type,
            try std.fmt.allocPrint(allocator, "items/{s}", .{field.name}),
            types.weaponTypeLabel(weapon_type),
            highlighted,
            button_color,
            item_icon_color,
            action,
        );
    }

    // Row 2: the non-weapon kinds (highlighted while the item is that
    // kind). Skill tomes are never offered — not level-authorable.
    const gear_kinds = [_]types.ItemKind{ .amulet, .coat, .gloves, .pants, .boots };
    for (gear_kinds, 0..) |kind, loop_index| {
        const highlighted = types.itemKindOf(item) == kind;
        try emitInspectorItemTypeCell(
            elements,
            allocator,
            gear_row,
            @intCast(loop_index),
            kind,
            null,
            itemIconSpriteId(types.itemOfKind(kind, "")),
            types.itemKindLabel(kind),
            highlighted,
            button_color,
            item_icon_color,
            action,
        );
    }
}

/// One type-pick cell (the weapon-slot cells' visual class): the
/// `ui/item_slot` button carrying the pick payload (the kind + the
/// weapon type on weapon cells) + the item icon overlay, aspect-fitted
/// + tinted.
fn emitInspectorItemTypeCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    row: Rectangle,
    ordinal: i32,
    kind: types.ItemKind,
    weapon_type: ?types.WeaponType,
    icon_sprite_id: []const u8,
    tooltip_label: []const u8,
    highlighted: bool,
    button_color: Color,
    item_icon_color: Color,
    action: types.Action,
) !void {
    const cell_size = row.height;
    const cell: Rectangle = .{
        .x = row.x + ordinal * (cell_size + ui_gap),
        .y = row.y,
        .width = cell_size,
        .height = cell_size,
    };
    try elements.append(allocator, .{ .button = .{
        .sprite_id = "ui/item_slot",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = action,
        .editor_item_kind = kind,
        .editor_weapon_type = weapon_type,
        .color = button_color,
        .highlighted = highlighted,
        .tooltip = .{ .header = try spanRow(allocator, text(tooltip_label)) },
    } });
    const fitted = scaleToFit(cell, inventory_slot_size, inventory_slot_size);
    try elements.append(allocator, .{ .image = .{
        .sprite_id = icon_sprite_id,
        .screen_position = fitted.position(),
        .width = fitted.width,
        .height = fitted.height,
        .color = item_icon_color,
        .blocks_input = false,
    } });
}

/// A gear slot's control line: Add while the slot is empty (creates a
/// default item), Delete while an item is equipped (clears to null). The
/// item's own name/stat fields follow as separate entries.
fn emitInspectorGearSlot(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    context: InspectorEntityContext,
    slot: types.GearSlot,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const button_color = context.gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const occupied = context.template.gearSlotItem(slot) != null;
    const label: []const u8 = if (occupied) "Delete" else "Add";
    const action: types.Action = if (occupied) .delete_editor_item else .add_editor_item;
    // Half the panel width — full-width reads as a section header.
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try emitInspectorSlotButton(
        elements,
        allocator,
        font_metrics,
        rect,
        label,
        action,
        slot,
        button_color,
        active_theme.lightest,
    );
}

/// A full-rect panel-backed slot button (Add / Delete): panel + spriteless
/// button + centered label — the toggle's visual class.
fn emitInspectorSlotButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    rect: Rectangle,
    label: []const u8,
    action: types.Action,
    slot: types.GearSlot,
    button_color: Color,
    label_color: Color,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = action,
        .editor_gear_slot = slot,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = label_color,
        .blocks_input = false,
    } });
}

/// The decoration content's Footprint row's control: a half-width
/// panel-backed button showing the tile count — clicking opens the
/// centered footprint editor (the sprite button's look, its own action).
fn emitInspectorFootprintButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    label: []const u8,
    button_color: Color,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = .open_editor_footprint_picker,
        .tooltip = .{ .header = try spanRow(allocator, text("Edit footprint")) },
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// A layer row's label (1-based for display): "Layer N" / "Layer N color".
fn inspectorLayerLabel(
    allocator: std.mem.Allocator,
    layer_index: u32,
    with_color_suffix: bool,
) ![]const u8 {
    const number = layer_index + 1;
    return if (with_color_suffix)
        std.fmt.allocPrint(allocator, "Layer {d} color", .{number})
    else
        std.fmt.allocPrint(allocator, "Layer {d}", .{number});
}

/// One layer's slot row (the Layers section): the control line holds the
/// sprite-stem button (a re-pick opens the layer picker for this index) +
/// a Delete button — the weapon-slot row's layout, entity + decoration
/// content alike (the actions + button color differ per kind).
fn emitInspectorLayerRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    sprite: []const u8,
    layer_index: u32,
    open_action: types.Action,
    delete_action: types.Action,
    button_color: Color,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    // The sprite-stem button (half width, the base sprite button's look).
    const sprite_rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = sprite_rect.position(),
        .width = sprite_rect.width,
        .height = sprite_rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = sprite_rect.position(),
        .width = sprite_rect.width,
        .height = sprite_rect.height,
        .action = open_action,
        .editor_layer = layer_index,
        .tooltip = .{ .header = try spanRow(allocator, text("Pick sprite")) },
    } });
    const label = if (sprite.len > 0) sprite else "(none)";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = sprite_rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    // The Delete button (quarter width, flush right of the stem button).
    const delete_rect: Rectangle = .{
        .x = sprite_rect.x + sprite_rect.width + ui_gap,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 4),
        .height = control_rect.height,
    };
    try emitInspectorLayerButton(
        elements,
        allocator,
        font_metrics,
        delete_rect,
        "Delete",
        delete_action,
        layer_index,
        button_color,
        active_theme.lightest,
    );
}

/// A panel-backed layer button with a centered label (Delete / Pick
/// sprite) carrying the layer-index payload — `emitInspectorSlotButton`'s
/// visual class (null layer index = the add-layer button).
fn emitInspectorLayerButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    rect: Rectangle,
    label: []const u8,
    action: types.Action,
    layer_index: ?u32,
    button_color: Color,
    label_color: Color,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = action,
        .editor_layer = layer_index,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = label_color,
        .blocks_input = false,
    } });
}
/// A utility-skill slot's control line: a half-width button showing the
/// slot's current skill (or "None") — clicking opens the centered skill
/// picker for that slot.
/// The utility-skill bar as ONE row of five 128×128 skill slots — the
/// entity-inspect skill look: occupied = skill-button frame + full-size
/// icon + skill tooltip; empty = the `ui/skill_slot_empty` diamond. Every
/// slot opens the centered picker (the slot index rides the button). The
/// context carries the team gradient, so the enemy + player inspectors
/// share the row.
fn emitInspectorUtilitySkillRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    context: InspectorEntityContext,
    row_rect: Rectangle,
) !void {
    const skill_frame_color = context.gradient_colors[3];
    const skill_icon_color = context.gradient_colors[1];
    const cell_size = editor_inspector_row_height;
    const cell_pitch = cell_size + ui_gap;
    for (0..types.utility_skill_count) |loop_index| {
        const slot_index: u32 = @intCast(loop_index);
        const cell: Rectangle = .{
            .x = row_rect.x + @as(i32, @intCast(loop_index)) * cell_pitch,
            .y = row_rect.y,
            .width = cell_size,
            .height = cell_size,
        };
        const current: ?types.SkillId = context.template.equipped_utility_skills[loop_index];
        if (current) |skill_id| {
            const tooltip: ?Tooltip = if (lookups.getSkillDefinition(skill_id)) |definition|
                try buildSkillTooltip(allocator, definition)
            else
                null;
            try elements.append(allocator, .{ .button = .{
                .sprite_id = "ui/skill_button",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .open_editor_skill_picker,
                .editor_utility_slot = slot_index,
                .color = skill_frame_color,
                .tooltip = tooltip,
            } });
            try elements.append(allocator, .{ .image = .{
                .sprite_id = skillIconSpriteId(skill_id),
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = skill_icon_color,
                .blocks_input = false,
            } });
        } else {
            // Empty slot — the diamond marker (the skill-bar look); the
            // tooltip names the pick target.
            try elements.append(allocator, .{ .button = .{
                .sprite_id = "ui/skill_slot_empty",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .open_editor_skill_picker,
                .editor_utility_slot = slot_index,
                .color = skill_frame_color,
                .tooltip = .{ .header = try spanRow(allocator, text("None")) },
            } });
        }
    }
}

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

/// M2 press arbitration for a focused text field (see DESIGN → UI
/// Framework → Text input widget): true when a left press may PROCEED
/// after committing the field — the press is on a sibling control of the
/// field's own panel (anything inside the open inspector panel or the
/// open metadata sidebar, or either toggle button); false when it must be
/// consumed as pure dismissal. Callers gate on a focused field before
/// calling; `pressed_button` is the button under the press position, if
/// any (the toggle buttons sit outside their panel rects, so they are
/// matched by action).
pub fn textEditPressProceeds(
    inspector_open: bool,
    metadata_sidebar_open: bool,
    position: ScreenPosition,
    pressed_button: ?Action,
) bool {
    if (pressed_button) |action| {
        if (action == .toggle_editor_inspector) return true;
        if (action == .toggle_editor_metadata_sidebar) return true;
        // A picker surface (a skill cell, a sprite cell, a picker tab, or
        // the close button): the picker is the ACTIVE interaction — commit
        // the field and let the pick fire in the same click (it floats
        // outside the panel rects, so the region checks below wouldn't
        // cover it).
        if (action == .select_editor_utility_skill or
            action == .select_editor_entity_sprite or
            action == .select_editor_sprite_tab or
            action == .close_editor_picker) return true;
    }
    if (inspector_open and editorInspectorPanelRect().contains(position)) return true;
    if (metadata_sidebar_open and editorMetadataSidebarPanelRect().contains(position)) return true;
    return false;
}

/// Editor bottom bar: the tool palette. Fixed tools first
/// (Select, Tile), then three groups — Enemies, Decorations, Items —
/// each a header toggle + a square panel "+" (add-new) cell + one slot per
/// palette type. Expanded groups put their header + "+" in the strip above
/// the bar; collapsed (or empty) groups put them flush against the bottom
/// of the screen. Every tool renders the shared button background plus a
/// distinguishing graphic: Select = `world/tile_highlight` frame 0, Tile =
/// `world/tile`, enemies = entity base sprite (enemy gradient at the
/// template's color_index), decorations = base sprite (world gradient at
/// the type's color_index), ground items = the item icon (ground items
/// always render as the shared ground bag in-world, so the palette shows
/// the ITEM's icon for authoring distinction). Interaction is wired: tool
/// cells make themselves the active tool (`player_set_editor_tool`),
/// headers toggle collapse, and the "+" cells append a new type from the
/// shipped defaults (`player_add_editor_*_type`) — the enemy/decoration
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

    const group_labels = [_][]const u8{ "Enemies", "Decorations", "Items" };
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
    // gap AFTER the "+" (not eaten by it) — and an expanded group whose
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
    // move the fixed tools — left-anchoring keeps Select/Tile stable.
    const bar = screen.placeBottomLeft(content_width, bottom_bar_height, 0);
    var row = Row.init(bar.position(), bottom_bar_height, ui_gap);

    // Fixed tools. The tile graphic draws at half size (the tile art is
    // busy at full cell scale).
    try emitEditorToolCell(
        elements,
        allocator,
        row.next(slot_size),
        .select,
        "world/tile_highlight",
        .{ .x = 0, .y = 0, .width = tile_highlight_frame_size, .height = tile_highlight_frame_size },
        tile_highlight_frame_size,
        tile_highlight_frame_size,
        1.0,
        active_theme.lightest,
        button_color,
        "Select",
        active_tool,
    );
    try emitEditorToolCell(
        elements,
        allocator,
        row.next(slot_size),
        .tile,
        "world/tile",
        null,
        tile_highlight_frame_size,
        tile_highlight_frame_size,
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
    // the bar (labeling the cells below); a COLLAPSED (or empty) group has
    // no cells to label, so they drop flush against the bottom of the
    // screen instead of hovering above the bar — same condition the
    // footprint math uses.
    for (group_labels, 0..) |label, group_index| {
        const size = group_sizes[group_index];
        const group_left = bar.x + row.cursor_x;
        const footprint = footprints[group_index];
        const header_y: i32 = if (collapsed[group_index] or size == 0)
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
            .editor_group = group_index,
            .tooltip = .{ .header = try spanRow(allocator, text(
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ label, if (collapsed[group_index]) "(collapsed)" else "" }),
            )) },
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
        // header (adjacent — reads as tied to the group; the gap keeps
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
            try std.fmt.allocPrint(allocator, "Add new {s} type", .{label}),
            .add_editor_palette_type,
            group_index,
        );

        // Type cells: the visible window (skipped entirely when collapsed).
        if (!collapsed[group_index] and size > 0) {
            // Clamp the window offset in place (authoritative — the wheel
            // handler also bounds-checks, but the builder owns the truth).
            const max_offset: i32 = @intCast(size -| editor_palette_max_tools);
            scroll_offsets[group_index] = @min(@max(scroll_offsets[group_index], 0), max_offset);
            const first_visible: usize = @intCast(scroll_offsets[group_index]);
            const visible = @min(size, editor_palette_max_tools);

            switch (group_index) {
                0 => for (editor.entity_types[first_visible .. first_visible + visible], 0..) |type_definition, ordinal| {
                    const sprite_id = try std.fmt.allocPrint(
                        allocator,
                        "entities/{s}",
                        .{type_definition.template.sprite},
                    );
                    const color_index = @min(type_definition.template.color_index, types.gradient_color_count - 1);
                    try emitEditorToolCell(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .entity_type = @intCast(first_visible + ordinal) },
                        sprite_id,
                        null,
                        editor_entity_frame_width,
                        editor_entity_frame_height,
                        1.0,
                        enemy[color_index],
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
                    const sprite_id = try std.fmt.allocPrint(
                        allocator,
                        "decorations/{s}",
                        .{type_definition.sprite},
                    );
                    const color_index = @min(type_definition.color_index, types.gradient_color_count - 1);
                    try emitEditorToolCell(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .decoration_type = @intCast(first_visible + ordinal) },
                        sprite_id,
                        null,
                        type_definition.pixel_dims.x,
                        type_definition.pixel_dims.y,
                        1.0,
                        world[color_index],
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
                        null,
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
        // gap (explicit — groups don't use `Row.next`, whose per-cell
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

/// A square ui/panel "+" cell (the editor's add-new affordance — palette
/// group pluses and the level-tab add-level plus). Inert until its edit
/// verb lands: a tooltip-carrying panel + a non-blocking centered "+"
/// glyph, same visual class as the level tabs. `cell` should be square.
fn emitEditorPlusCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    panel_color: Color,
    text_color: Color,
    tooltip_header: []const u8,
    action: ?types.Action,
    editor_group: ?usize,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = panel_color,
        .tooltip = .{ .header = try spanRow(allocator, text(tooltip_header)) },
    } });
    // Interactive "+" cells (the palette groups' add-new) carry a
    // spriteless button over the panel, the group-header class; a null
    // action leaves the cell inert (the add-level "+" until its handler
    // lands) — tooltip only.
    if (action) |some_action| {
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .action = some_action,
            .editor_group = editor_group,
        } });
    }
    const plus_width = font_metrics.measureSpanWidth(text("+"), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = "+",
        .screen_position = cell.placeCenter(plus_width, editor_group_header_font_size).position(),
        .font_size = editor_group_header_font_size,
        .color = text_color,
        .blocks_input = false,
    } });
}

/// Build the inventory panel into `bounds`: a 9-slice background, an 8×12
/// flush grid of `ui/item_slot` cells tinted with player-gradient index 5,
/// and a 128-wide material-count sidebar on the right. `bounds` is the
/// panel's outer rectangle (sized to `inventory_panel_width` ×
/// `middle_panel_height`); the grid sits `ui_gap` inside the top-left, the
/// sidebar sits `ui_gap` right of the grid. Each occupied slot emits an item
/// `Image` + a `SlotRef` (drag source / click target). Font size for the
/// material-count labels in the inventory sidebar (fits
/// Inset from a material icon's bottom-right corner to its count label.
pub const material_count_inset = ui_emit.material_count_inset;

/// One entry in the inventory sidebar's material stack.
/// Static display info for one material kind (the parts that don't vary by
/// context). The single source of truth for the five-material icon set —
/// every material-icon site in the UI reads from `material_kinds` so the
/// sprite / color / name mapping can't drift between them. Counts are
/// context-specific (inventory totals vs mission-complete harvest vs new-
/// clone summary) and supplied per site via a `types.Materials` value.
const MaterialKind = struct {
    sprite_id: []const u8,
    color_index: u32,
    /// Display name for the tooltip (e.g. "Wood").
    name: []const u8,
};

/// The five material kinds in display order (top-to-bottom for vertical
/// stacks, left-to-right for horizontal rows).
const material_kinds = [_]MaterialKind{
    .{ .sprite_id = "ui/material_wood", .color_index = 5, .name = "Wood" },
    .{ .sprite_id = "ui/material_metal", .color_index = 2, .name = "Metal" },
    .{ .sprite_id = "ui/material_leather", .color_index = 5, .name = "Leather" },
    .{ .sprite_id = "ui/material_cloth", .color_index = 2, .name = "Cloth" },
    .{ .sprite_id = "ui/material_knowledge", .color_index = 0, .name = "Knowledge" },
};

/// Read the count for `kind_index` out of `materials`. Kept as a switch so
/// adding a material kind is a compile error until every index is handled.
fn materialCount(materials: types.Materials, kind_index: usize) u32 {
    return switch (kind_index) {
        0 => materials.wood,
        1 => materials.metal,
        2 => materials.leather,
        3 => materials.cloth,
        4 => materials.knowledge,
        else => unreachable,
    };
}

/// Layout direction for `emitMaterialIcons`: `.vertical` stacks icons flush
/// (no gap, step = icon_size downward); `.horizontal` spaces them with
/// `ui_gap` (step = icon_size + ui_gap rightward). Matches the two layouts
/// the material-icon sites use (sidebar / harvest column = vertical;
/// new-clone summary row = horizontal).
const MaterialIconDirection = enum { vertical, horizontal };

/// Emit the five material icons (each a blocking `Image` with a
/// `{count} {name}` tooltip) plus a non-blocking outlined count label in
/// each icon's bottom-right corner. Walks `material_kinds` in display order
/// starting at `origin` (top-left of the first icon), stepping by
/// `direction`. `materials` supplies the per-kind counts. The shared body
/// for the inventory sidebar, the mission-complete harvest column, and the
/// new-clone summary row — so the icon set + tooltip format can't drift.
fn emitMaterialIcons(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    origin: ScreenPosition,
    icon_size: i32,
    direction: MaterialIconDirection,
    materials: types.Materials,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    var pos = origin;
    for (material_kinds, 0..) |kind, index| {
        const count = materialCount(materials, index);
        const icon_color = p[@min(kind.color_index, types.gradient_color_count - 1)];
        const tooltip_text = try std.fmt.allocPrint(allocator, "{d} {s}", .{ count, kind.name });
        try elements.append(allocator, .{ .image = .{
            .sprite_id = kind.sprite_id,
            .screen_position = pos,
            .width = icon_size,
            .height = icon_size,
            .color = icon_color,
            .tooltip = .{ .header = try spanRow(allocator, text(tooltip_text)) },
        } });
        // Count label: bottom-right corner of the icon, outlined for
        // readability over the icon art. Passes hover through to the icon
        // so the icon's tooltip is the single target.
        const count_text = try std.fmt.allocPrint(allocator, "{d}", .{count});
        const label_width = font_metrics.measureSpanWidth(text(count_text), material_count_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = count_text,
            .screen_position = .{
                .x = pos.x + icon_size - label_width - material_count_inset,
                .y = pos.y + icon_size - material_count_font_size - material_count_inset,
            },
            .font_size = material_count_font_size,
            .outlined = true,
            .blocks_input = false,
        } });
        switch (direction) {
            .vertical => pos.y += icon_size,
            .horizontal => pos.x += icon_size + ui_gap,
        }
    }
}

/// Build the inventory panel into `bounds`: a 9-slice background, an 8×12
/// flush grid of `ui/item_slot` cells (each carrying an inventory `SlotRef`
/// so press/click/drag handlers can resolve which slot was acted on), and a
/// 128-wide sidebar on the right. The sidebar stacks the five material
/// icons bottom-aligned (each with an outlined count label + a `{count}
/// {type}` tooltip) and tops them with the salvage-tool indicator (display-
/// only, outlined while Shift is held). A shift+left-drag over the grid
/// renders a lightest stroked outline around the bounding box of the
/// selected region (see `UiState.salvage_region`). `bounds` is the panel's
/// outer rectangle (sized to `inventory_panel_width` ×
/// `middle_panel_height`); the grid sits `ui_gap` inside the top-left,
/// the sidebar sits `ui_gap` right of the grid.
/// Sprite id for an item's inventory/gear icon. Weapons resolve per
/// `WeaponType` (Unity's `WandItem` maps to our `staff`); gear types have
/// one icon each; `skill_tome` uses a single generic tome icon (the taught
/// skill is separate info; a per-skill tome icon is not wired — see TODO →
/// UI Framework). All item icons live under `assets/items/` at 128×128
/// (ported from the Unity `Resources/Items/` sprites at native size). See
/// DESIGN → UI Framework.
pub fn itemIconSpriteId(item: types.Item) []const u8 {
    return switch (item) {
        .weapon => |weapon| switch (weapon.weapon_type) {
            .sword => "items/sword",
            .shield => "items/shield",
            .spear => "items/spear",
            .dagger => "items/dagger",
            .axe => "items/axe",
            .staff => "items/staff",
        },
        .amulet => "items/amulet",
        .coat => "items/coat",
        .gloves => "items/gloves",
        .pants => "items/pants",
        .boots => "items/boots",
        .skill_tome => "items/skill_tome",
    };
}

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
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, player_one, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

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

    // Tabs sit right of the top bar's options + undo cells, 128 high,
    // flush against the top of the screen.
    const start_x = 2 * (slot_size + ui_gap);
    try std.testing.expectEqual(@as(i32, start_x), elements.items[0].nine_slice_panel.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), elements.items[0].nine_slice_panel.screen_position.y);
    try std.testing.expectEqual(@as(i32, 128), elements.items[0].nine_slice_panel.height);

    // Per tab: the button carries the payload + action; only the ACTIVE
    // tab (index 1) is highlighted. Labels: the level's name, else
    // "Level N".
    const expected_labels = [_][]const u8{ "The Crossing", "Level 2", "Level 3" };
    var previous_x: i32 = start_x;
    for (0..3) |tab| {
        const button = elements.items[4 * tab + 1].button;
        try std.testing.expectEqual(Action.select_editor_level, button.action);
        try std.testing.expectEqual(@as(u32, @intCast(tab)), button.editor_level.?);
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
        try std.testing.expectEqual(@as(u32, @intCast(tab)), close_button.editor_level.?);
        try std.testing.expectEqual(close_button_size, close_button.width);
        try std.testing.expectEqual(@as(i32, 0), close_button.screen_position.y);
        const tab_panel = elements.items[4 * tab].nine_slice_panel;
        try std.testing.expectEqual(
            tab_panel.screen_position.x + tab_panel.width - close_button_size,
            close_button.screen_position.x,
        );
        // The widened tab: the label sits fully clear of the ×'s zone
        // (centered in the area left of it — the tab grew by exactly
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
    // top-aligned with the tabs, carrying the tooltip — a BUTTON now
    // (spriteless over the panel): `.add_editor_level` appends the
    // template level.
    const plus_panel = elements.items[12].nine_slice_panel;
    try std.testing.expectEqualStrings("ui/panel", plus_panel.sprite_id);
    try std.testing.expectEqual(@as(i32, 128), plus_panel.width);
    try std.testing.expectEqual(@as(i32, 128), plus_panel.height);
    try std.testing.expectEqual(@as(i32, 0), plus_panel.screen_position.y);
    try std.testing.expect(plus_panel.screen_position.x > previous_x);
    try std.testing.expect(plus_panel.tooltip != null);
    const plus_button = elements.items[13].button;
    try std.testing.expectEqual(Action.add_editor_level, plus_button.action);
    try std.testing.expect(plus_button.sprite_id == null);
    try std.testing.expectEqualStrings("+", elements.items[14].text_label.text);
    try std.testing.expect(!elements.items[14].text_label.blocks_input);

    // A single-level mission offers NO × (a mission always keeps ≥1 level
    // — the delete gate): one tab x (panel + button + label) + the "+"
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
}

test "buildEditorPrimaryActions: Test + Validate icon buttons flush top-right" {
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

    var elements: UiElementList = .empty;
    try buildEditorPrimaryActions(&elements, arena.allocator(), theme);

    // Two icon buttons, each a button + overlaying image = 4 elements.
    try std.testing.expectEqual(@as(usize, 4), elements.items.len);

    // Test first (elements 0-1), Validate right of it (2-3): the
    // options/undo visual class (slot_size square, top bar height) flush
    // against the right screen edge.
    const test_button = elements.items[0].button;
    try std.testing.expectEqual(Action.test_editor_level, test_button.action);
    try std.testing.expectEqualStrings(button_background_sprite_id, test_button.sprite_id.?);
    try std.testing.expectEqualStrings("ui/icon_playtest", elements.items[1].image.sprite_id);
    try std.testing.expectEqual(@as(i32, types.reference_width - 2 * slot_size - ui_gap), test_button.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), test_button.screen_position.y);
    try std.testing.expectEqual(slot_size, test_button.width);
    try std.testing.expectEqual(slot_size, test_button.height);
    try std.testing.expect(!elements.items[1].image.blocks_input); // button wins hit-test

    const validate_button = elements.items[2].button;
    try std.testing.expectEqual(Action.validate_editor_mission, validate_button.action);
    try std.testing.expectEqualStrings("ui/icon_validate", elements.items[3].image.sprite_id);
    try std.testing.expectEqual(@as(i32, types.reference_width - slot_size), validate_button.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), validate_button.screen_position.y);
    try std.testing.expectEqual(slot_size, validate_button.width);
    try std.testing.expectEqual(slot_size, validate_button.height);
}

test "buildEditorLevelTabs: overflow clamps the window, pins the +, follows the active tab" {
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
    // window shows exactly tab 7. (The active tab is 7 too — the
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
        // only on a CHANGE of the active tab (the regression — running it
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

test "buildEditorInspectorPanel: toggle button always, background panel only when open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const player_one: types.Color = .{ .r = 30, .g = 30, .b = 30 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, player_one, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    // Select tool, empty selection: the open panel carries the PLAYER
    // content (the fallback target) — ALL SECTIONS COLLAPSED by default:
    // five headers (+ markers) + spacers, everything fits, no scrollbar.
    const editor: types.Editor = .{};

    // Open (the default): toggle 3 + background panel + 5 section
    // headers × (panel + button + label) = 19 elements.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(usize, 19), elements.items.len);
        try expectInspectorToggleShape(&elements);
        try expectInspectorLabels(&elements, &.{ "+ Player", "+ Weapons", "+ Gear", "+ Utility skills", "+ Inventory" });
        // The player content tints with the PLAYER gradient (the strip at
        // element 4 uses gradient[5]).
        try std.testing.expectEqual(player_five, elements.items[4].nine_slice_panel.color);

        // The background panel: flush left, below the button, down to one
        // ui_gap above the expanded palette groups' header strip, tinted
        // darkest (the background-panel class — button panels tint
        // gradient[5]).
        const panel = elements.items[3].nine_slice_panel;
        try std.testing.expectEqualStrings("ui/panel", panel.sprite_id);
        try std.testing.expectEqual(@as(i32, 0), panel.screen_position.x);
        try std.testing.expectEqual(top_bar_height + ui_gap + editor_header_strip_height + ui_gap, panel.screen_position.y);
        try std.testing.expectEqual(editor_inspector_width, panel.width);
        // The expanded header strip's top (buildEditorBottomBar's
        // `bar.y - ui_gap - editor_header_strip_height`) sits one ui_gap
        // below the panel's bottom.
        const expanded_header_top = types.reference_height - bottom_bar_height - ui_gap - editor_header_strip_height;
        try std.testing.expectEqual(expanded_header_top - ui_gap, panel.screen_position.y + panel.height);
        try std.testing.expectEqual(theme.darkest, panel.color);
        try std.testing.expect(panel.blocks_input);
        // The builder draws exactly the shared rect fn — the M2 press
        // arbitration (`textEditPressProceeds`) reads the same geometry,
        // so the two cannot drift.
        try std.testing.expectEqual(
            editorInspectorPanelRect(),
            Rectangle{
                .x = panel.screen_position.x,
                .y = panel.screen_position.y,
                .width = panel.width,
                .height = panel.height,
            },
        );
    }

    // Closed: just the toggle (3 elements), no longer highlighted.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, false, &ui_state);
        try std.testing.expectEqual(@as(usize, 3), elements.items.len);
        try expectInspectorToggleShape(&elements);
    }
}

test "buildEditorInspectorPanel content: enemy tool rows windowed + clamped, scrollbar on overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, black, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
    };
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // 45 row units (6 sections × 1 + 17 two-unit entries — 4 identity
    // fields, 4 stats, 2 weapon slots, 5 gear slots, the utility-skill
    // row, the add-layer row — + 5 spacers); the panel fits 10 units, so
    // 35 units scroll + the scrollbar shows.
    const visible_rows = @divFloor(
        editorInspectorPanelRect().height - 2 * ui_gap,
        editor_inspector_row_height,
    );
    try std.testing.expectEqual(@as(i32, 10), visible_rows);

    // Scroll 0: units 0..10 — Identity, Name, Sprite, Color, Displays
    // weapons, then the section-break spacer (the Stats header starts at
    // 10 and needs the spacer's unit too → next window).
    // Elements: toggle 3 + bg 1 + Identity 3 (panel + button + label) +
    // Name 1 (text field) + Sprite 3 (panel + picker button + label) +
    // Color
    // (label + 6 swatch fills + 6 swatch buttons = 13) + Displays weapons
    // (label + panel + button + value label = 4) + scrollbar 2 = 29.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(usize, 32), elements.items.len);
        try expectInspectorLabels(&elements, &.{ "- Identity", "Name", "Sprite", "(none)", "Color", "Displays weapons", "true" });
        // 6 swatch fills + the 2 scrollbar rects.
        try std.testing.expectEqual(@as(usize, 8), countSolidRects(&elements));
    }

    // Scroll 3: the window opens at Sprite and runs through the spacer +
    // the Stats header + Max health (Defense doesn't fully fit).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 3, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "Sprite", "(none)", "Color", "Displays weapons", "true", "- Stats", "Max health" });
    }

    // Out-of-range scroll clamps to max (45 − 10 = 35, the five spacers
    // included): the window is the last gear slot + the utility section +
    // the skill row + the Layers tail.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 999, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(i32, 35), ui_state.editor_inspector_scroll);
        try expectInspectorLabels(&elements, &.{
            "Boots", "Add", "- Utility skills", "Skill bar", "- Layers", "Add layer", "Pick sprite",
        });
        // The skill row: five 128×128 picker buttons — three empty (the
        // diamond sprite) and this template has no skills equipped, so
        // all five are empty diamonds.
        var picker_slot_buttons: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .open_editor_skill_picker) {
                picker_slot_buttons += 1;
                try std.testing.expectEqualStrings("ui/skill_slot_empty", button.sprite_id.?);
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 5), picker_slot_buttons);
    }

    // Negative scroll clamps to 0.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = -4 };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(i32, 0), ui_state.editor_inspector_scroll);
    }

    // A stale tool id (the type deleted mid-edit) falls back to the PLAYER
    // content — its scroll CLAMPS (45 units − 10 visible = 35: the summary
    // grew into the 16-row slot grid), no reset; the bottom window lands on
    // the grid's last ten rows (pure slot cells — no text labels).
    {
        const stale_editor: types.Editor = .{
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 7 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 999, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, stale_editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(i32, 35), ui_state.editor_inspector_scroll);
        try expectInspectorLabels(&elements, &.{});
        // Ten visible rows × six cells; the window ends at the grid's end
        // (slot 95) and nothing is selected.
        var slot_buttons: usize = 0;
        var highest_slot: u32 = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_inventory_slot) {
                slot_buttons += 1;
                highest_slot = @max(highest_slot, button.editor_inventory_slot.?);
                try std.testing.expect(!button.highlighted);
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 60), slot_buttons);
        try std.testing.expectEqual(@as(u32, 95), highest_slot);
        // No swatches in the window — only the scrollbar rects are solid.
        try std.testing.expectEqual(@as(usize, 2), countSolidRects(&elements));
    }
}

test "inspector utility-skill row: occupied slots show the skill, empty the diamond" {
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

    // Slot 1 carries blink, the rest are empty.
    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton", .template = .{
        .equipped_utility_skills = .{ null, .blink, null, null, null },
    } }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // Scroll to the bottom — the window lands on the skill row.
    var elements: UiElementList = .empty;
    var ui_state: UiState = .{ .editor_inspector_scroll = 999, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
    try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);

    // Five picker buttons: blink's slot is the skill button, the rest
    // the empty diamond. Every slot rides its index.
    var slot_buttons: usize = 0;
    var blink_slot: ?u32 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_editor_skill_picker) {
            slot_buttons += 1;
            if (button.editor_utility_slot == 1) {
                try std.testing.expectEqualStrings("ui/skill_button", button.sprite_id.?);
                blink_slot = button.editor_utility_slot;
            } else {
                try std.testing.expectEqualStrings("ui/skill_slot_empty", button.sprite_id.?);
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), slot_buttons);
    try std.testing.expectEqual(@as(?u32, 1), blink_slot);

    // The occupied slot carries the full-size skill icon (the entity-
    // inspect look) with the icon tint from the gradient's index 1 — and
    // the row's geometry: 128×128 cells pitched 128 + ui_gap.
    var saw_blink_icon = false;
    for (elements.items) |element| switch (element) {
        .image => |image| if (std.mem.eql(u8, image.sprite_id, skillIconSpriteId(.blink))) {
            saw_blink_icon = true;
            try std.testing.expectEqual(@as(i32, 128), image.width);
            try std.testing.expectEqual(@as(i32, 128), image.height);
        },
        else => {},
    };
    try std.testing.expect(saw_blink_icon);

    // Slot pitch: consecutive picker buttons advance by 128 + ui_gap.
    var previous_x: ?i32 = null;
    var pitches: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_editor_skill_picker) {
            if (previous_x) |x| {
                try std.testing.expectEqual(editor_inspector_row_height + ui_gap, button.screen_position.x - x);
                pitches += 1;
            }
            previous_x = button.screen_position.x;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), pitches);
}

test "inspector player content: gear + skills + inventory over player_def, commits target player_def" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, black, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // An equipped loadout: a main-hand weapon, an amulet, blink in slot 0,
    // two inventory items.
    var inventory: types.Inventory = .{};
    inventory.slots[3] = .{ .weapon = .{ .name = "Spare Sword", .weapon_type = .sword, .weapon_damage = 2 } };
    inventory.slots[4] = .{ .weapon = .{ .name = "Spare Axe", .weapon_type = .axe, .weapon_damage = 2 } };
    const editor: types.Editor = .{
        .player_def = .{ .id = "Player", .template = .{
            .name = "New Player",
            .main_hand_weapon = .{ .name = "Starter Sword", .weapon_type = .sword, .weapon_damage = 3 },
            .amulet = .{ .name = "Starter Amulet", .spell_damage = 3 },
            .equipped_utility_skills = .{ .blink, null, null, null, null },
            .inventory = inventory,
        } },
        .active_tool = .select,
        .selection = &.{.{ .player_start = {} }},
    };

    // Window [7,17): the main hand's slot row + its item fields + the
    // off-hand row + the Gear header. The weapon's text fields carry
    // `.player_def` — the player content's commits route there.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 7, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "Main hand", "Delete", "Main hand name", "Main hand damage", "Off hand", "- Gear" });
        const name_field = findTextField(&elements, .{ .item_name = .main_hand }).?;
        try std.testing.expectEqualStrings("Starter Sword", name_field.text);
        try std.testing.expectEqual(types.TextEditTarget{ .entity = .player_def }, name_field.ref.target);
        const damage_field = findTextField(&elements, .{ .item_stat = .{ .slot = .main_hand, .stat = .weapon_damage } }).?;
        try std.testing.expectEqualStrings("3", damage_field.text);
        // The equipped hand shows its Delete (not Add).
        var main_hand_delete = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .delete_editor_item and
                button.editor_gear_slot.? == .main_hand)
            {
                main_hand_delete = true;
            },
            else => {},
        };
        try std.testing.expect(main_hand_delete);
    }

    // The Import row: BOTH buttons render — Player data (the session
    // import) and Max player (the shipped max loadout).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 3, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var player_data_button = false;
        var max_player_button = false;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .import_editor_player) player_data_button = true;
                if (button.action == .import_editor_max_player) max_player_button = true;
            },
            else => {},
        };
        try std.testing.expect(player_data_button);
        try std.testing.expect(max_player_button);
    }

    // Bottom window (scroll 29: Boots → the skill row → the Inventory
    // header + the grid's first two rows): blink occupied in slot 0, the
    // rest diamonds; the two inventory items (slots 3 + 4, row 0) render
    // their icon overlays. The full grid replaced the old summary.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 29, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "Boots", "Add", "- Utility skills", "Skill bar", "- Inventory" });
        var occupied_slots: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .open_editor_skill_picker) {
                if (button.editor_utility_slot == 0) {
                    try std.testing.expectEqualStrings("ui/skill_button", button.sprite_id.?);
                    occupied_slots += 1;
                } else {
                    try std.testing.expectEqualStrings("ui/skill_slot_empty", button.sprite_id.?);
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), occupied_slots);
        // The grid's first two rows: 12 cells, two carrying item icons.
        var slot_buttons: usize = 0;
        var icon_overlays: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_inventory_slot) {
                slot_buttons += 1;
            },
            .image => |image| if (std.mem.startsWith(u8, image.sprite_id, "items/")) {
                icon_overlays += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 12), slot_buttons);
        try std.testing.expectEqual(@as(usize, 2), icon_overlays);
    }
}

/// All inspector sections expanded — the content tests' standard state
/// (the shipped default is ALL COLLAPSED; see
/// `UiState.editor_inspector_section_expanded`). Pub for the main.zig
/// focus-on-click test, which builds the inspector through the real view.
pub fn allInspectorSectionsExpanded() [editor_inspector_section_count]bool {
    return .{true} ** editor_inspector_section_count;
}

/// Assert the inspector's content labels, in order, skipping the toggle
/// button's own "Inspector" label (elements 0-2 are the toggle group, 3
/// the background panel).
fn expectInspectorLabels(elements: *const UiElementList, expected: []const []const u8) !void {
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(std.testing.allocator);
    for (elements.items[4..]) |element| switch (element) {
        .text_label => |label| try labels.append(std.testing.allocator, label.text),
        else => {},
    };
    try std.testing.expectEqual(expected.len, labels.items.len);
    for (expected, labels.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

fn countSolidRects(elements: *const UiElementList) usize {
    var count: usize = 0;
    for (elements.items) |element| switch (element) {
        .solid_rect => count += 1,
        else => {},
    };
    return count;
}

/// Shared shape checks for the inspector toggle button (the level-tab
/// visual class): panel-backed cell flush left below the options button,
/// 128 high, label + side padding wide, spriteless button carrying the
/// action + tooltip. Never highlighted (the label carries the state).
fn expectInspectorToggleShape(elements: *const UiElementList) !void {
    const panel = elements.items[0].nine_slice_panel;
    try std.testing.expectEqualStrings("ui/panel", panel.sprite_id);
    try std.testing.expectEqual(@as(i32, 0), panel.screen_position.x);
    try std.testing.expectEqual(top_bar_height + ui_gap, panel.screen_position.y);
    try std.testing.expectEqual(editor_header_strip_height, panel.height);
    try std.testing.expect(panel.width >= editor_header_strip_height);

    const button = elements.items[1].button;
    try std.testing.expectEqual(Action.toggle_editor_inspector, button.action);
    try std.testing.expect(!button.highlighted);
    try std.testing.expect(button.sprite_id == null);
    try std.testing.expect(button.tooltip != null);

    const label = elements.items[2].text_label;
    try std.testing.expectEqualStrings("Inspector", label.text);
    try std.testing.expect(!label.blocks_input);
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
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    var entity_template: types.Entity = .{};
    entity_template.sprite = "skeleton";
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

    // 2 fixed tools x (bg + graphic) + 3 groups x (header panel + button
    // + label + plus (panel + button + glyph) + type (bg + graphic + delete
    // button)) = 4 + 27.
    try std.testing.expectEqual(@as(usize, 31), elements.items.len);

    // Every tool graphic sits on a button_background cell at the bottom of the
    // screen: 5 tool cells (2 fixed + 3 palette types) — the "+" cells are
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
    try std.testing.expectEqual(@as(usize, 5), background_count);

    // Fixed tools: Select uses tile_highlight frame 0 (a source rectangle,
    // not the whole 1024-wide sheet); Tile uses world/tile tinted with the
    // world gradient index 1.
    var found_select_frame = false;
    var found_tile = false;
    var found_enemy = false;
    var found_decoration = false;
    var found_item = false;
    for (elements.items) |element| switch (element) {
        .image => |image| {
            if (std.mem.eql(u8, image.sprite_id, "world/tile_highlight")) {
                found_select_frame = image.source_rectangle != null;
            } else if (std.mem.eql(u8, image.sprite_id, "world/tile")) {
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
    try std.testing.expect(found_select_frame);
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
            // The header + "+" buttons BOTH carry the group payload — tell
            // them apart by action.
            if (button.editor_group == 0 and button.action == .toggle_editor_palette_group) {
                enemies_header_button = button.screen_position;
                enemies_header_width = button.width;
            }
            if (button.editor_group == 1 and button.action == .toggle_editor_palette_group) {
                decorations_header_button = button.screen_position;
            }
            if (button.action == .add_editor_palette_type) {
                plus_button_count += 1;
                try std.testing.expect(button.editor_group != null);
                try std.testing.expect(button.sprite_id == null); // spriteless over the panel
                if (button.editor_group.? == 0) enemies_plus_button = button.screen_position;
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
                try std.testing.expect(button.editor_tool != null);
            }
            if (button.sprite_id != null and
                std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                // Cells emit in order: Select, Tile, enemy, …
                if (enemy_cell_index == 2) first_enemy_cell = button.screen_position;
                enemy_cell_index += 1;
            }
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Enemies")) {
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

test "buildEditorBottomBar: collapsed groups sit flush bottom; expanded hover above" {
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

    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton" }};
    const editor: types.Editor = .{ .entity_types = &entity_types };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 0, 0 };
    // Enemies (group 0) expanded; Decorations + Items collapsed.
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
            if (button.editor_group) |group_index| {
                group_header_y[group_index] = button.screen_position.y;
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
            if (button.editor_group == 1) decoration_header_x = button.screen_position.x;
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
}

test "buildEditorBottomBar: group window clamps to max 8 tools + scrolls" {
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

    // The over-scrolled offset clamps to size - max = 12 - 8 = 4; negative
    // would clamp to 0.
    try std.testing.expectEqual(@as(i32, 4), scroll_offsets[1]);

    // Count decoration tool cells: exactly 8 (the window). Tooltips live
    // on the button_background image, which is emitted immediately BEFORE
    // its graphic — pair them by position. The window starting at 4 shows
    // types 4..11 — the FIRST type ("Ruin 0") is NOT among them, the LAST
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
    try std.testing.expectEqual(@as(usize, 8), decoration_cells);
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
            ) and button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                count += 1;
            },
            else => {},
        };
        break :blk count;
    };
    // 2 fixed + 1 enemy + 8 decorations + 1 item (pluses are in the
    // header strip, out of the bar band).
    try std.testing.expectEqual(@as(usize, 12), tool_backgrounds);

    // The 5th background cell (index 4) is the first decoration window
    // cell — cells are emitted in order: Select, Tile, enemy, enemy-plus,
    // decorations (8), decoration-plus, item, item-plus.
    var cell_index: usize = 0;
    var decoration_cell_center: ?types.ScreenPosition = null;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.sprite_id == null) continue;
            if (!std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id)) continue;
            if (button.screen_position.y < types.reference_height - bottom_bar_height) continue;
            defer cell_index += 1;
            if (cell_index == 4) {
                decoration_cell_center = .{
                    .x = button.screen_position.x + @divTrunc(button.width, 2),
                    .y = button.screen_position.y + @divTrunc(button.height, 2),
                };
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
    // Fixed tool (first cell): null — not a palette group.
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

test "inspector Layers sections: per-layer rows + add button (enemy + decoration)" {
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

    // ENEMY content with one layer: the clamped window lands on the
    // utility row + the whole Layers section.
    {
        const entity_layers = [_]types.EntityLayer{.{ .sprite = "hood", .color_index = 2 }};
        const entity_types = [_]types.EntityTypeDef{.{
            .id = "Skeleton",
            .template = .{
                .name = "Skeleton",
                .sprite = "skeleton_1",
                .team = 1,
                .layers = &entity_layers,
            },
        }};
        const editor: types.Editor = .{
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_inspector_scroll = 999,
            .editor_inspector_section_expanded = allInspectorSectionsExpanded(),
        };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{
            "Skill bar", "- Layers", "Layer 1", "hood", "Delete", "Layer 1 color", "Add layer", "Pick sprite",
        });

        // The layer slot row: the stem button opens the ENTITY layer
        // picker for index 0; Delete carries the same payload. The color
        // swatches carry the layer index + the layer-color action, the
        // current index (2) highlighted.
        var saw_stem_button = false;
        var saw_delete = false;
        var swatch_count: usize = 0;
        var highlighted_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .open_editor_entity_layer_picker and
                    button.editor_layer != null and button.editor_layer.? == 0)
                {
                    saw_stem_button = true;
                }
                if (button.action == .delete_editor_entity_layer and
                    button.editor_layer != null and button.editor_layer.? == 0)
                {
                    saw_delete = true;
                }
                if (button.action == .select_editor_entity_layer_color) {
                    try std.testing.expectEqual(@as(u32, 0), button.editor_layer.?);
                    swatch_count += 1;
                    if (button.highlighted) highlighted_count += 1;
                }
            },
            else => {},
        };
        try std.testing.expect(saw_stem_button);
        try std.testing.expect(saw_delete);
        try std.testing.expectEqual(@as(usize, 6), swatch_count);
        try std.testing.expectEqual(@as(usize, 1), highlighted_count);
    }

    // DECORATION content with one layer: the clamped window lands on the
    // footprint row + the whole Layers section (world-gradient swatches).
    {
        const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
        const decoration_layers = [_]types.DecorationLayer{.{
            .sprite = "tree_1_canopy",
            .color_index = 2,
            .pixel_dims = .{ .x = 512, .y = 256 },
        }};
        const decoration_types = [_]types.DecorationTypeDef{.{
            .id = "stone_2",
            .sprite = "stone_2",
            .footprint = &footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
            .layers = &decoration_layers,
        }};
        const editor: types.Editor = .{
            .decoration_types = &decoration_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_inspector_scroll = 999,
            .editor_inspector_section_expanded = allInspectorSectionsExpanded(),
        };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{
            "Footprint", "2 tiles", "- Layers", "Layer 1", "tree_1_canopy", "Delete", "Layer 1 color", "Add layer", "Pick sprite",
        });

        var swatch_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_layer_color) {
                try std.testing.expectEqual(@as(u32, 0), button.editor_layer.?);
                swatch_count += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 6), swatch_count);
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

test "buildEditorMetadataSidebar: collapsible sections, windowed rows, scrollbar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 5 ++ .{player_five} },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const levels = [_]types.EditorLevel{
        .{ .name = "First" },
        // Player colors on MANUAL (an explicit override) so the scrolled
        // case covers both outline modes.
        .{ .name = "Second", .player_gradient_index = 2 },
    };
    const editor: types.Editor = .{
        .levels = &levels,
        .mission = .{ .name = "My Mission" },
        .active_level_index = 1,
    };

    // The toggle button: always present, flush RIGHT at the inspector
    // toggle's height.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorMetadataSidebar(&elements, arena.allocator(), metrics, editor, theme, false, &ui_state);
        try std.testing.expectEqual(@as(usize, 3), elements.items.len);
        try std.testing.expectEqual(Action.toggle_editor_metadata_sidebar, elements.items[1].button.action);
        const toggle_panel = elements.items[0].nine_slice_panel;
        try std.testing.expectEqual(top_bar_height + ui_gap, toggle_panel.screen_position.y);
        try std.testing.expectEqual(types.reference_width, toggle_panel.screen_position.x + toggle_panel.width);
    }

    // Open + COLLAPSED (the default): the background panel + two section
    // headers only — the inspector's all-collapsed convention. 10 = toggle
    // 3 + panel 1 + two strips × (panel + button + label).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorMetadataSidebar(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(usize, 10), elements.items.len);
        // The strips are the shared collapsible headers (+ marker, the
        // toggle action, the section id payload).
        var headers: [2]?Button = .{ null, null };
        var headers_seen: [2]bool = .{ false, false };
        for (elements.items) |element| switch (element) {
            .button => |button| switch (button.action) {
                .toggle_editor_inspector_section => switch (button.editor_section.?) {
                    .mission => headers[0] = button,
                    .current_level => headers[1] = button,
                    else => {},
                },
                else => {},
            },
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "+ Mission")) headers_seen[0] = true;
                if (std.mem.eql(u8, label.text, "+ Current level")) headers_seen[1] = true;
            },
            else => {},
        };
        try std.testing.expect(headers[0] != null);
        try std.testing.expect(headers[1] != null);
        try std.testing.expect(headers_seen[0]);
        try std.testing.expect(headers_seen[1]);
        // No fields while collapsed.
        for (elements.items) |element| try std.testing.expect(element != .text_field);
    }

    // Open + EXPANDED: the entries window like the inspector's (13 units
    // of content, 10 visible) — at scroll 0 the mission + level name
    // fields and the WORLD row are visible, the enemy/player rows are
    // not (they don't fully fit); the scrollbar appears.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_inspector_section_expanded = allInspectorSectionsExpanded(),
        };
        try buildEditorMetadataSidebar(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);

        var mission_field: ?TextFieldUi = null;
        var level_field: ?TextFieldUi = null;
        var open_buttons: [3]?Button = .{ null, null, null };
        var scrollbar_rects: usize = 0;
        for (elements.items) |element| switch (element) {
            .text_field => |field| switch (field.ref.id) {
                .mission_name => mission_field = field,
                .level_name => level_field = field,
                else => {},
            },
            .button => |button| switch (button.action) {
                .open_editor_level_gradient_picker => switch (button.editor_gradient_role.?) {
                    .world => open_buttons[0] = button,
                    .enemy => open_buttons[1] = button,
                    .player => open_buttons[2] = button,
                },
                else => {},
            },
            .solid_rect => |rect| {
                // Scrollbar track + thumb (the fixed grays).
                if (std.meta.eql(rect.color, types.Color{ .r = 80, .g = 80, .b = 80 }) or
                    std.meta.eql(rect.color, types.Color{ .r = 180, .g = 180, .b = 180 }))
                {
                    scrollbar_rects += 1;
                }
            },
            else => {},
        };
        try std.testing.expect(mission_field != null);
        try std.testing.expectEqualStrings("My Mission", mission_field.?.text);
        try std.testing.expectEqual(types.TextEditTarget.mission, mission_field.?.ref.target);
        try std.testing.expect(level_field != null);
        try std.testing.expectEqualStrings("Second", level_field.?.text);
        try std.testing.expectEqual(types.TextEditTarget{ .level = 1 }, level_field.?.ref.target);
        try std.testing.expect(open_buttons[0] != null);
        try std.testing.expect(open_buttons[1] == null);
        try std.testing.expect(open_buttons[2] == null);
        // The WORLD swatch is ALWAYS outlined (its index is always an
        // explicit pick — no Auto state to carry the outline instead).
        try std.testing.expect(open_buttons[0].?.highlighted);
        try std.testing.expectEqual(@as(usize, 2), scrollbar_rects);
    }

    // Scrolled to the bottom: the player row is visible, the mission
    // name field is not (windowed out).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_inspector_section_expanded = allInspectorSectionsExpanded(),
            .editor_metadata_scroll = 99, // clamped to 3 by the builder
        };
        try buildEditorMetadataSidebar(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var mission_field_seen = false;
        var player_button: ?Button = null;
        var enemy_auto_button: ?Button = null;
        var enemy_swatch_button: ?Button = null;
        var player_auto_button: ?Button = null;
        for (elements.items) |element| switch (element) {
            .text_field => |field| {
                if (field.ref.id == .mission_name) mission_field_seen = true;
            },
            .button => |button| switch (button.action) {
                .open_editor_level_gradient_picker => switch (button.editor_gradient_role.?) {
                    .enemy => enemy_swatch_button = button,
                    .player => player_button = button,
                    else => {},
                },
                .toggle_editor_level_gradient_auto => switch (button.editor_gradient_role.?) {
                    .enemy => enemy_auto_button = button,
                    .player => player_auto_button = button,
                    else => {},
                },
                else => {},
            },
            else => {},
        };
        try std.testing.expect(!mission_field_seen);
        try std.testing.expect(player_button != null);
        // The outline marks the mode: enemy (auto) → the AUTO button
        // outlined, the swatch not; player (manual, override 2) → the
        // SWATCH outlined, the Auto button not.
        try std.testing.expect(enemy_auto_button.?.highlighted);
        try std.testing.expect(!enemy_swatch_button.?.highlighted);
        try std.testing.expect(!player_auto_button.?.highlighted);
        try std.testing.expect(player_button.?.highlighted);
        // The scroll CLAMPED to the content max (13 units - 10 visible).
        try std.testing.expectEqual(@as(i32, 3), ui_state.editor_metadata_scroll);
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

test "inspector inventory grid: detail block inserts below the selected slot's row; Add/Delete + item rows by occupancy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, black, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    var inventory: types.Inventory = .{};
    inventory.slots[4] = .{ .amulet = .{ .name = "Starter Amulet", .spell_damage = 3 } };
    const editor: types.Editor = .{
        .player_def = .{ .id = "Player", .template = .{
            .name = "New Player",
            .inventory = inventory,
        } },
        .active_tool = .select,
        .selection = &.{.{ .player_start = {} }},
    };

    // No selection: bare slot rows only — the section header plus cells,
    // no detail entries anywhere.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 28, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{"- Inventory"});
        var detail_buttons: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .add_editor_inventory_item or
                button.action == .delete_editor_inventory_item or
                button.action == .select_editor_inventory_item_type)
            {
                detail_buttons += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 0), detail_buttons);
    }

    // Selected OCCUPIED slot 4 (row 0): the detail block inserts directly
    // below row 0 — Delete (not Add), the type rows (the amulet cell
    // highlighted), name + spell damage fields, all targeting slot 4.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_inspector_scroll = 29,
            .editor_inspector_section_expanded = allInspectorSectionsExpanded(),
            .editor_inventory_selected_slot = 4,
        };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "Slot 5", "Delete", "Type", "Name", "Spell damage" });
        const name_field = findTextField(&elements, .inventory_item_name).?;
        try std.testing.expectEqualStrings("Starter Amulet", name_field.text);
        try std.testing.expectEqual(types.TextEditTarget{ .inventory_slot = 4 }, name_field.ref.target);
        const stat_field = findTextField(&elements, .{ .inventory_item_stat = .spell_damage }).?;
        try std.testing.expectEqualStrings("3", stat_field.text);
        // The selected cell is highlighted; the Delete button carries
        // the slot payload.
        var selected_highlighted = false;
        var delete_button = false;
        var amulet_highlighted = false;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .select_editor_inventory_slot and
                    button.editor_inventory_slot.? == 4 and button.highlighted)
                {
                    selected_highlighted = true;
                }
                if (button.action == .delete_editor_inventory_item and
                    button.editor_inventory_slot.? == 4)
                {
                    delete_button = true;
                }
                if (button.action == .select_editor_inventory_item_type and
                    button.editor_item_kind.? == .amulet and button.highlighted)
                {
                    amulet_highlighted = true;
                }
            },
            else => {},
        };
        try std.testing.expect(selected_highlighted);
        try std.testing.expect(delete_button);
        try std.testing.expect(amulet_highlighted);
    }

    // Selected EMPTY slot 13 (row 2): Add only — no type rows, no fields
    // (author decision: an empty slot shows Add until an item exists).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_inspector_scroll = 28,
            .editor_inspector_section_expanded = allInspectorSectionsExpanded(),
            .editor_inventory_selected_slot = 13,
        };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "- Inventory", "Slot 14", "Add" });
        var add_button = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .add_editor_inventory_item and
                button.editor_inventory_slot.? == 13)
            {
                add_button = true;
            },
            else => {},
        };
        try std.testing.expect(add_button);
        try std.testing.expect(findTextField(&elements, .inventory_item_name) == null);
        var type_cells: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_inventory_item_type) {
                type_cells += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 0), type_cells);
    }
}
