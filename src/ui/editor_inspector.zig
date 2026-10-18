//! The editor inspector + metadata sidebar: `buildEditorInspectorPanel`
//! (the left inspector: toggle + background + the windowed field-content
//! pipeline over entity/decoration/item/player targets) and
//! `buildEditorMetadataSidebar` (the right sidebar's mission/level name +
//! gradient rows), the inspector target inference (`editorInspectorTarget`
//! - shared with the input layer), the field-control emitters, and the
//! M2 press arbitration (`textEditPressProceeds`). See DESIGN → Level
//! Editor → Editor UI layout.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const shell = @import("editor_shell.zig");
const ui_state_mod = @import("state.zig");
const text_input = @import("text_input.zig");
const ui_tooltip = @import("tooltip.zig");
const utility_skills = @import("../utility_skills.zig");
const lookups = @import("../generated_lookups.zig");
const census = @import("../test_ui_census.zig");
const loaders = @import("../loaders.zig");
const Skill = @import("../skill.zig").Skill;

const Action = types.Action;
const ScreenPosition = types.ScreenPosition;
const Rectangle = types.Rectangle;
const Color = types.Color;
const Entity = types.Entity;
const GearSlot = types.GearSlot;
const SkillId = types.SkillId;
const GameState = @import("../state.zig").GameState;
const UiState = ui_state_mod.UiState;
const editor_inspector_section_count = ui_state_mod.editor_inspector_section_count;
const Span = ui_element.Span;
const Tooltip = ui_element.Tooltip;
const TooltipRow = ui_element.TooltipRow;
const text = ui_element.text;
const colored = ui_element.colored;
const bold = ui_element.bold;
const FontMetrics = ui_element.FontMetrics;
const UiElement = ui_element.UiElement;
const UiElementList = ui_element.UiElementList;
const TextFieldUi = ui_element.TextFieldUi;
const Button = ui_element.Button;
const Slot = ui_element.Slot;
const Image = ui_element.Image;
const slot_size = ui_element.slot_size;
const ui_gap = ui_element.ui_gap;
const slot_padding = ui_element.slot_padding;
const small_icon_size = ui_element.small_icon_size;
const default_tint = ui_element.default_tint;
const close_button_size = ui_element.close_button_size;
const screenRect = ui_element.screenRect;
const scaleToFit = shell.scaleToFit;
const editor_header_strip_height = shell.editor_header_strip_height;
const editor_entity_frame_width = shell.editor_entity_frame_width;
const editor_entity_frame_height = shell.editor_entity_frame_height;
const editor_group_header_font_size = shell.editor_group_header_font_size;
const top_bar_height = ui_element.top_bar_height;
const inventory_slot_size = ui_element.inventory_slot_size;
const beginTextEdit = text_input.beginTextEdit;
const routeTextInput = text_input.routeTextInput;
const bottom_bar_height = ui_element.bottom_bar_height;
const emitIconButton = emit.emitIconButton;
const emitPanelButton = emit.emitPanelButton;
const itemIconSpriteId = emit.itemIconSpriteId;
const skillIconSpriteId = emit.skillIconSpriteId;
const buildSkillTooltip = ui_tooltip.buildSkillTooltip;
const spanRow = ui_tooltip.spanRow;
const TextEditState = text_input.TextEditState;

/// Width of the editor inspector sidebar's background panel. Placeholder
/// value - revisit once the field layout lands and the real width is
/// visible.
const editor_inspector_width: i32 = 1024;

/// The Inventory section's slot-grid width: six square 128px cells fit a
/// row with room for the gap rhythm; 16 rows × 6 = the full
/// `inventory_slot_count` (the same 96 slots the in-game 8×12 grid
/// shows - intentionally identical capacity, arranged to fit the panel).
const editor_inventory_slots_per_row: u32 = 6;
const editor_inventory_row_count: u32 = types.inventory_slot_count / editor_inventory_slots_per_row;

/// The inspector background panel's rect - the single source for the
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
/// side padding wide), and - when open - a background panel underneath it
/// that will host the active tool's field editors (later slices; empty for
/// now). The panel spans from below the button down to one `ui_gap` above
/// the expanded palette groups' header strip (those headers sit `ui_gap` +
/// one strip above the bottom bar; the extra gap keeps the panel from
/// sitting flush against them - their x range overlaps the panel since the
/// bottom bar is flush left). The open flag lives on the Editor (GameState)
/// - the toggle rides the undo timeline via `editor_toggle_inspector`.
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
    } });
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = button_cell.placeCenter(label_width, editor_group_header_font_size).position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    // Background panel (when open): from below the button to one ui_gap
    // above the expanded palette groups' header strip. Theme darkest -
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
/// sidebars - full sidebar-panel height, a `ui_gap` in from each sidebar
/// panel's edge. CONSTANT (independent of the sidebars' open state - the
/// pickers keep their rect regardless; the gameplay scenes' middle-panel
/// band is the model). The pickers' CONTENTS are fixed-size (256px cells,
/// fixed strips) laid out inside it - the overlay never resizes with its
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
const editor_metadata_sidebar_width: i32 = 1024;

/// The metadata sidebar's panel rect - the inspector rect mirrored to the
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
/// (the same visual class), and - when open - a background panel hosting
/// the mission + active-level metadata: the Mission section (name field)
/// and the Level section (name field; the gradient rows land with the
/// theme slice). The open flag lives on the Editor (GameState) - the
/// toggle rides the undo timeline via `editor_toggle_metadata_sidebar`.
/// See DESIGN → Architecture → Level Editor → Editor UI layout (Settings
/// sidebar).
pub fn buildEditorMetadataSidebar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    color_theme_definitions: types.ColorThemeDefinitions,
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

    // Content: the INSPECTOR'S EXACT MODEL - a per-frame entry list over
    // the expansion state, view-relative windowed emission (only rows
    // that FULLY fit), and a scrollbar when the content overflows. Both
    // sections COLLAPSED by default; the strips are the shared
    // collapsible section headers (`emitInspectorSectionStrip` - the +/-
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
    // the commit). A level-less editor (defensive - open_editor
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
        color_theme_definitions,
        &ui_state.editor_inspector_section_expanded,
    );

    // Unit math + scroll clamp - the inspector's (authoritative here: the
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
            // A blank unit - the section-break gap.
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
                font_metrics,
                row,
                button_color,
                cell,
                active_theme,
            ),
        }
    }

    // Scrollbar (only when the content overflows): the inspector's
    // geometry - track + proportional thumb in the right `ui_gap` margin,
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
            .color = ui_element.scrollbar_track_color,
        } });
        const thumb_height = @max(
            ui_element.scrollbar_thumb_min_height,
            @divTrunc(track_height * visible_rows, total_units),
        );
        const thumb_y = track_y +
            @divTrunc(scroll_offset.* * (track_height - thumb_height), max_scroll_row);
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = thumb_y },
            .width = editor_inspector_scrollbar_width,
            .height = thumb_height,
            .color = ui_element.scrollbar_thumb_color,
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
    /// The role's EFFECTIVE gradient index (the override while manual, the
    /// auto-derived one otherwise - `loaders.effectiveGradientIndex`). Null
    /// on the level-less defensive path - no number shown.
    effective_index: ?u32,
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
/// WHILE EXPANDED (the shared `editor_inspector_section_expanded` state -
/// collapse is a view affordance, off the undo timeline). The spacer
/// belongs to the section ABOVE it (a collapsed section takes no gap).
fn editorMetadataEntries(
    allocator: std.mem.Allocator,
    level: ?types.EditorLevel,
    active_theme: types.ActiveColorTheme,
    color_theme_definitions: types.ColorThemeDefinitions,
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
                .effective_index = levelEffectiveGradientIndex(
                    color_theme_definitions,
                    level,
                    .world,
                ),
            } },
            .{ .gradient = .{
                .label = "Enemy colors",
                .role = .enemy,
                .colors = active_theme.enemy_gradient.colors,
                .gradient_override = if (level) |some_level|
                    some_level.enemy_gradient_index
                else
                    null,
                .effective_index = levelEffectiveGradientIndex(
                    color_theme_definitions,
                    level,
                    .enemy,
                ),
            } },
            .{ .gradient = .{
                .label = "Player colors",
                .role = .player,
                .colors = active_theme.player_gradient.colors,
                .gradient_override = if (level) |some_level|
                    some_level.player_gradient_index
                else
                    null,
                .effective_index = levelEffectiveGradientIndex(
                    color_theme_definitions,
                    level,
                    .player,
                ),
            } },
        });
    }

    return entries.items;
}

/// A level's effective gradient index for a role (the shared
/// `loaders.effectiveGradientIndex` over the level's stored keys) - null
/// while there's no level to derive from (the defensive level-less path:
/// no number shown, mirroring the picker's stale-level no-highlight).
fn levelEffectiveGradientIndex(
    color_theme_definitions: types.ColorThemeDefinitions,
    level: ?types.EditorLevel,
    role: types.LevelGradientRole,
) ?u32 {
    const some_level = level orelse return null;
    return loaders.effectiveGradientIndex(
        color_theme_definitions,
        some_level.color_wheel_index,
        some_level.enemy_gradient_index,
        some_level.player_gradient_index,
        role,
    );
}

/// A metadata-sidebar gradient row (two-unit field entry, the inspector's
/// geometry): the role label line above, the control line below - the
/// role's EFFECTIVE gradient index flush right on the label line (the
/// number the theme picker's matching row carries - see
/// `EditorGradientRow.effective_index`), then the control line with the
/// AUTO toggle (enemy/player roles only) and the full-gradient swatch
/// strip, ONE button over the whole strip opening the theme picker.
/// `gradient_override` is null while the role auto-derives. The outline
/// marks the mode: the AUTO button while deriving, the SWATCH while an
/// explicit pick is in force (the world row's swatch always). The swatch
/// colors are the EFFECTIVE gradient either way (the active theme
/// already resolved them).
fn emitSidebarGradientRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    row: EditorGradientRow,
    button_color: types.Color,
    entry: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    // The descriptor line (the role's label), flush to the bottom of the
    // upper unit - the inspector's field-entry convention.
    try elements.append(allocator, .{ .text_label = .{
        .text = row.label,
        .screen_position = .{ .x = entry.x, .y = inspectorLabelY(entry) },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
    // The effective gradient's index, flush right on the same line (0-based,
    // matching the level's stored keys + the picker's row numbers).
    if (row.effective_index) |index| {
        const index_text = try std.fmt.allocPrint(allocator, "{d}", .{index});
        const index_text_width = font_metrics.measureSpanWidth(
            text(index_text),
            editor_group_header_font_size,
        );
        try elements.append(allocator, .{ .text_label = .{
            .text = index_text,
            .screen_position = .{
                .x = entry.x + entry.width - index_text_width,
                .y = inspectorLabelY(entry),
            },
            .font_size = editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
    }
    const control_rect = inspectorControlRect(entry);
    const role = row.role;
    const gradient_override = row.gradient_override;

    // The AUTO toggle (enemy/player rows only): highlighted while
    // deriving; a click while manual reverts (the input layer no-ops it
    // while auto - the same-value rule).
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
            .payload = .{ .editor_gradient_role = role },
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
    try elements.append(allocator, .{
        .button = .{
            .screen_position = swatch_rect.position(),
            .width = swatch_rect.width,
            .height = swatch_rect.height,
            .action = .open_editor_level_gradient_picker,
            .payload = .{ .editor_gradient_role = role },
            // The outline marks the row's mode: the AUTO button carries it
            // while deriving, the SWATCH while an explicit pick is in force
            // (the world row's swatch always - its index is always picked).
            // The backend renders it as the lightest stroked rect.
            .highlighted = role == .world or gradient_override != null,
            .tooltip = .{ .header = try spanRow(allocator, text("Pick gradient")) },
        },
    });
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

/// Inspector content row pitch - the 128px UNIT: a section header is one
/// unit; a field entry is TWO (the label line above, the editable value
/// below - one thing per line, full width).
pub const editor_inspector_row_height: i32 = editor_header_strip_height;

/// Inspector scrollbar track width, centered in the panel's right `ui_gap`
/// margin (the skills-panel precedent).
const editor_inspector_scrollbar_width = ui_element.scrollbar_width;

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
/// or item), or - while the select tool is active - the tool INFERRED
/// from the selection. The player is the fallback for everything else:
/// the tile tool, an empty or ambiguous selection, an unresolvable
/// reference. Inference rules: tiles and the '=' contribute NOTHING
/// (legitimately uninspectable - mixing them with enemies still shows the
/// enemy); the '!' contributes a `.player` REFERENCE (so player-start +
/// anything - or alone - resolves to the player); entity, decoration,
/// and ground-item placements contribute their type, resolved against
/// the ACTIVE level - an out-of-range placement index or a stale palette
/// type id is an unresolvable bug-state reference and forces the fallback
/// (the delete arms keep the selection consistent, so this is defensive
/// only - see `Selectable`). Exactly one distinct reference wins; two or
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
        // The tile tool has no fields - the player is the fallback.
        .tile => return .player,
    }
    if (editor.active_level_index >= editor.levels.len) return .player;
    const level = editor.levels[editor.active_level_index];
    var inferred: ?EditorInspectorTarget = null;
    for (editor.selection) |selected| {
        const referenced: ?EditorInspectorTarget = switch (selected) {
            // Legitimately uninspectable - contributes nothing (mixing
            // tiles / the '=' with enemies still shows the enemy).
            .tile, .level_end => null,
            .player_start => .player,
            .entity_placement => |index| blk: {
                // An out-of-range placement index or a stale palette type
                // id is an unresolvable bug-state reference - it can't
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
/// builder is the only consumer - the input-side commit sites map the
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
    /// official tabs - see DESIGN → Level Editor → Editor UI layout, the
    /// centered sprite picker).
    sprite_button: void,
    /// The color_index swatch row (the enemy gradient, one swatch per
    /// index - the settings screen's player-color row is the precedent).
    swatches,
    /// A true/false toggle strip (the FORMAT's "true"/"false" vocabulary).
    /// The plan builder resolves the current value + the flip action - the
    /// same emitter serves the entity (displays_weapons, keep colors) and
    /// decoration (keep colors) toggles.
    toggle: struct { current: bool, action: types.Action },
    /// The decoration content's sprite row - same button look as the
    /// entity `sprite_button`, reading the decoration context instead.
    decoration_sprite_button: void,
    /// The decoration content's color swatch row (the WORLD gradient -
    /// decorations index into it, matching the in-game tinting).
    decoration_swatches: void,
    /// The decoration content's footprint row: a button showing the tile
    /// count that opens the centered footprint editor (the tile-grid
    /// picker).
    footprint_button: void,
    /// A palette item TYPE's field (the Items group's content - name or
    /// one stat): the shared text-field element, reading the item context
    /// instead of an entity template.
    item_text: types.TextFieldId,
    /// An INVENTORY slot item's field (the player content's Inventory
    /// section detail rows - name or one stat): the shared text-field
    /// element, reading the selected slot's item.
    inventory_item_text: types.TextFieldId,
};

/// One line of inspector content - per the coupling contract in DESIGN →
/// Architecture → Level Editor → Editor UI layout → Inspector fields. The
/// list is built PER FRAME from the editor state (a present item adds its
/// sub-field rows after its slot row). Sections carry their identity (not
/// a label string): the id keys the expansion state + the label lookup.
const EditorInspectorEntry = union(enum) {
    section: types.EditorInspectorSectionId,
    /// One blank unit before every section header except the first - the
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
    /// The player loadout's name - a READ-ONLY value line (the name comes
    /// with the imported player data, it isn't hand-edited).
    player_name_line: void,
    /// The player inspector's Import button: copy the session's player
    /// data (or the new-game default, with none) into the loadout.
    import_player: void,
    /// One ROW of the player loadout's inventory slot grid (six cells;
    /// `editor_inventory_slots_per_row`). While the section's selected
    /// slot sits in this row, the detail entries follow directly below
    /// (the per-frame insert - see editorInspectorPlayerEntries).
    inventory_slot_row: u32,
    /// The selected inventory slot's Add/Delete row: the "Slot N" label
    /// line + the half-width button (Add while the slot is empty, Delete
    /// while an item is present). The FIRST detail entry below the
    /// selected slot's row.
    inventory_item_button: u32,
    /// The selected inventory slot's type-pick rows (3 units: the "Type"
    /// label line + the weapon row + the gear-kind row) - emitted ONLY
    /// while an item exists in the slot (author decision: an empty slot
    /// shows Add until an item does).
    inventory_item_type_rows: void,
    /// One ENEMY layer's slot row (label "Layer N"): the sprite-stem
    /// button (re-pick via the layer picker) + Delete. The Layers section
    /// is enemy content only - the player loadout has no layers.
    entity_layer: u32,
    /// One enemy layer's color swatch row (the enemy gradient).
    entity_layer_color: u32,
    /// The enemy content's add-layer row (opens the picker in add mode).
    add_entity_layer: void,
    /// One DECORATION layer's slot row - the entity_layer shape over the
    /// decoration context.
    decoration_layer: u32,
    /// One decoration layer's color swatch row (the world gradient).
    decoration_layer_color: u32,
    /// The decoration content's add-layer row.
    add_decoration_layer: void,
    /// The item content's type-pick rows (3 units): the "Type" label line
    /// + the weapon-type row + the non-weapon-kind row. A differing pick
    /// resets the item ("New <Kind>", zeroed stats) - the pick handler's
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
/// only offers these - a stat the item doesn't have commits nothing by
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

/// The item content's standalone stat label (capitalized first letter -
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
/// the equipped item's fields. The spacer BEFORE Weapons is the caller's -
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
/// field `parseEntityDefinition` reads (the coupling contract - anything
/// editable by text-editing the level file is a row here). Each section
/// header is followed by its children WHILE EXPANDED (collapsed sections
/// carry the header only - see `UiState.editor_inspector_section_expanded`).
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
            .{ .field = .{ .label = "Team", .control = .{ .text = .{ .entity_stat = .team } } } },
            .{ .field = .{ .label = "Sprite", .control = .sprite_button } },
            // The Keep colors toggle sits ABOVE the swatches (it decides
            // whether they apply), and the Color row is HIDDEN while the
            // flag is on - a tint row under an untinted type is a dead,
            // confusing control (the swatches do nothing).
            .{ .field = .{ .label = "Keep colors", .control = .{ .toggle = .{
                .current = template.keep_original_colors,
                .action = .toggle_editor_entity_keep_original_colors,
            } } } },
        });
        if (!template.keep_original_colors) {
            try entries.append(allocator, .{ .field = .{ .label = "Color", .control = .swatches } });
        }
        try entries.append(allocator, .{ .field = .{ .label = "Displays weapons", .control = .{ .toggle = .{
            .current = template.displays_weapons,
            .action = .toggle_editor_entity_displays_weapons,
        } } } });
        // The section-break spacer belongs to the section ABOVE it - a
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
    // row, then the add button. The LAST section - the spacer above it
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

/// The PLAYER content's entries (the fallback target - the '!' spawn's
/// loadout): the loadout header + (while expanded) the read-only name line
/// + import button, the shared Weapons / Gear / Utility sections, and the
/// inventory SLOT GRID (16 rows of six cells). While a slot is selected,
/// its detail entries insert directly BELOW its slot row - the first
/// in-section expansion in the inspector (the entries list is rebuilt per
/// frame, so the insert is a conditional append): the Add/Delete row
/// first, then - only while an item exists (author decision: no type
/// rows while empty) - the type-pick rows + name + stats, mirroring the
/// item tool inspector exactly. No Identity / Stats sections - base
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
        // The section-break spacer belongs to the section ABOVE it - a
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
            // The detail block - directly below the selected slot's row.
            try entries.append(allocator, .{ .inventory_item_button = selected.? });
            const item = template.inventory.slots[selected.?] orelse continue;
            try entries.append(allocator, .{ .inventory_item_type_rows = {} });
            // A skill tome has no name (it IS its skill) - no name row,
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

/// The DECORATION content's entries: Identity (sprite + color - a
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
            // Above the swatches; the Color row is hidden while the flag
            // is on (the entity plan's rule - a dead tint control under an
            // untinted type confuses more than it informs).
            .{ .field = .{ .label = "Keep colors", .control = .{ .toggle = .{
                .current = definition.keep_original_colors,
                .action = .toggle_editor_decoration_keep_original_colors,
            } } } },
        });
        if (!definition.keep_original_colors) {
            try entries.append(allocator, .{ .field = .{ .label = "Color", .control = .decoration_swatches } });
        }
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
    // row, then the add button. The LAST section - the spacer above it
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
/// collapsible section - the type-pick rows (weapon types + non-weapon
/// kinds; a differing pick resets the item), then the name field + one
/// numeric field per stat the kind carries. Skill tomes carry neither a
/// name nor stats (and are never offered by the pick rows - not
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
        // A skill tome has no name (it IS its skill) - no name row.
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
/// `buildEditorInspectorPanel`): the resolved target's entries - the
/// active entity tool's field rows, or the player loadout (the fallback
/// target). View-relative windowed emission
/// (the skills-panel model): only FULLY visible rows are emitted at the top
/// of the content region, so nothing half-draws or overflows the panel; the
/// scrollbar thumb conveys the position. `scroll_offset` (rows) is clamped
/// here - authoritative, this fn knows the content height. The wheel
/// routes here from handleAnytimeInput when the pointer is inside the panel
/// rect; while a text field is focused the wheel still flows (only key
/// bindings are suppressed).
/// A section-header strip: panel-backed, the label left-padded and
/// vertically centered (the group-header visual class) - and the section's
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
        .payload = .{ .editor_section = section },
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
/// enemy gradient, player content = player gradient - matching the
/// entity-inspect panel's team-gradient coloring).
pub const InspectorEntityContext = struct {
    template: types.Entity,
    edit_target: types.EntityEditTarget,
    gradient_colors: [types.gradient_color_count]types.Color,
};

/// The decoration type an inspector content path edits, resolved from
/// the inspector target: the definition its controls read. Coloring is
/// the WORLD gradient (decorations index into it, matching the in-game
/// tinting) - carried by the active theme, not this struct.
pub const InspectorDecorationContext = struct {
    type_definition: types.DecorationTypeDef,
};

/// The palette item type an inspector content path edits, resolved from
/// the inspector target: the ItemTypeDef its controls read. Carries the
/// palette index (the text-field refs' `.item_type` target). Coloring is
/// the PLAYER gradient (matching the Items palette group's tinting).
pub const InspectorItemContext = struct {
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

    // Target resolution: the active entity/decoration tool, a selection of
    // placements that all reference one type, or the PLAYER fallback (the
    // '!' spawn's loadout) - see editorInspectorTarget. All paths share
    // the windowing machinery below; they differ in entries + context.
    // Exactly one context is populated (the one its entries read).
    const target = editorInspectorTarget(editor);
    const entity_context: ?InspectorEntityContext = switch (target) {
        .entity_type => |index| .{
            .template = editor.entity_types[index].template,
            .edit_target = .{ .entity_type = index },
            // The team gradient, matching the in-game tinting: a team-0
            // enemy type is a player-team helper and tints with the PLAYER
            // gradient (see DESIGN → Entity & UI Coloring).
            .gradient_colors = if (editor.entity_types[index].template.team == 0)
                active_theme.player_gradient.colors
            else
                active_theme.enemy_gradient.colors,
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

    // Team gradient throughout - the context's gradient (enemy content
    // enemy, player content player; matching the entity-inspect panel's
    // team-gradient coloring). Decoration content tints with the WORLD
    // gradient instead (the in-game decoration tinting) - one button
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
    // an entry is emitted only when it FULLY fits the visible window -
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
            // A blank unit - the section-break gap.
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
            // value below it - full content width, one thing per line.
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
                    // The decoration content's sprite row - same emitter,
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
                    // A palette item TYPE's field (name / stat) - the same
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
                    // An inventory slot item's field (name / stat) - the
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
                    // The decoration content's swatch row - the WORLD
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
                    .toggle => |toggle| try emitInspectorToggle(
                        elements,
                        allocator,
                        font_metrics,
                        toggle.current,
                        toggle.action,
                        button_color,
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
            // 128×128 skill slots - the entity-inspect look (skill-button
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
            // The player loadout's name - a read-only value line (the
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
            // The Import row: TWO half-width buttons - Player data (the
            // session's data, or the new-game default with none) and Max
            // player (the shipped data/max_player.txt loadout - the
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
            // cell selects the slot - the detail entries below are the
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
            // half-width button - Add while the slot is empty, Delete
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
            // The selected slot's type-pick rows - the item tool
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
            // One ENEMY layer: the slot row - the sprite-stem button (a
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
                    null,
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
            // One DECORATION layer - the entity arms' shape over the
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
                    decoration_context.?.type_definition.layers[layer_index].behind,
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
            // pick resets the item - see emitInspectorItemTypeRows).
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
    // thumb in the right `ui_gap` margin - the skills-panel geometry,
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
            .color = ui_element.scrollbar_track_color,
        } });
        const thumb_height = @max(
            ui_element.scrollbar_thumb_min_height,
            @divTrunc(track_height * visible_rows, total_units),
        );
        const thumb_y = track_y +
            @divTrunc(scroll_offset.* * (track_height - thumb_height), max_scroll_row);
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = thumb_y },
            .width = editor_inspector_scrollbar_width,
            .height = thumb_height,
            .color = ui_element.scrollbar_thumb_color,
        } });
    }
}

/// Emit one inspector text field in the row's control column. The builder
/// computes ALL render data (it owns the metrics + the focused buffer):
/// the display text is the live buffer while THIS field is focused, else
/// the field's current value; the caret/selection geometry is measured
/// from the buffer. Display text is duped into the frame allocator - an
/// element slice must never point into UiState (it mutates between
/// frames, and the previous frame's elements are hit-tested a frame
/// later).
/// The base-sprite row's control (entity + decoration content): a
/// half-width panel-backed button showing the current stem's FILE NAME
/// (a custom namespaced stem displays as its last path segment - see
/// `spriteDisplayName`) - clicking opens the centered sprite picker (the
/// input site routes entity vs decoration by the inspector target).
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
    const label = if (sprite.len > 0) spriteDisplayName(sprite) else "(none)";
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
/// content's exact shape over the selected slot's item - the slot index
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
/// per slot (`ui/item_slot` button + item icon overlay while occupied -
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
            .payload = .{ .editor_inventory_slot = slot_index },
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
/// player): panel-backed spriteless button + centered label - the
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
    // Half the panel width - full-width reads as a section header.
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
        .payload = .{ .editor_inventory_slot = slot_index },
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
/// exact shape over the item context - `itemTextFieldValue` is the value
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
/// frame, pure-black text - the contrast is the point; the caret +
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
/// player-color row is the precedent - colored fill + invisible payload
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
            .payload = if (layer_index) |li|
                .{ .editor_layer_color = .{ .layer_index = li, .color_index = @intCast(index) } }
            else
                .{ .editor_color = @intCast(index) },
            .highlighted = current_index == index,
        } });
    }
}

/// A true/false toggle strip: a panel-backed button showing the current
/// value in the FORMAT's vocabulary ("true"/"false" - the exact tokens
/// `asBool` parses); clicking flips it via `action`. Shared by the entity
/// + decoration toggle rows (the plan resolves current + action).
fn emitInspectorToggle(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    current: bool,
    action: types.Action,
    button_color: Color,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const label: []const u8 = if (current) "true" else "false";
    // Half the panel width - full-width reads as a section header; the
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
        .action = action,
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
/// button background - the palette tool-cell visual class). Picking a type
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
            .payload = .{ .editor_weapon_type_cell = .{ .gear_slot = hand, .weapon_type = weapon_type } },
            .color = button_color,
            .highlighted = highlighted,
            .tooltip = .{ .header = try spanRow(allocator, text(types.weaponTypeLabel(weapon_type))) },
        } });
        // The item icon (the inventory's `items/<type>` art - the author
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
/// row, the five non-weapon kinds on the second (skill tomes excluded -
/// not authorable as ground items). The weapon-slot cells' visual class
/// (`ui/item_slot` button + the `items/<type>` icon, palette tinting).
/// Any pick that DIFFERS from the current item resets it to a
/// "New <Kind>" default with zeroed stats (author decision - no
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
    // kind). Skill tomes are never offered - not level-authorable.
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
        .payload = .{ .editor_item_kind_cell = .{ .kind = kind, .weapon_type = weapon_type } },
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
    // Half the panel width - full-width reads as a section header.
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
/// button + centered label - the toggle's visual class.
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
        .payload = .{ .editor_gear_slot = slot },
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
/// panel-backed button showing the tile count - clicking opens the
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

/// The display form of a sprite stem: the FILE STEM only. Official stems
/// are already bare (`skeleton_1`); custom mission-bundled stems are
/// namespaced `custom/<mission-dir>/<stem>` - the path is identity for
/// the config + the pick payloads, noise for the author. A suffix slice
/// of the input (no allocation).
fn spriteDisplayName(sprite: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, sprite, '/')) |slash| return sprite[slash + 1 ..];
    return sprite;
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
/// sprite-stem button (showing the stem's FILE NAME - `spriteDisplayName`
/// - a re-pick opens the layer picker for this index) +
/// a Delete button - the weapon-slot row's layout, entity + decoration
/// content alike (the actions + button color differ per kind).
fn emitInspectorLayerRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    sprite: []const u8,
    layer_index: u32,
    open_action: types.Action,
    delete_action: types.Action,
    /// The layer's current draw side (decoration layers - Back/Front
    /// button), or null when the row's kind has no draw side (entity
    /// layers are overlays only).
    behind: ?bool,
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
        .payload = .{ .editor_layer = layer_index },
        .tooltip = .{ .header = try spanRow(allocator, text("Pick sprite")) },
    } });
    const label = if (sprite.len > 0) spriteDisplayName(sprite) else "(none)";
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

    // The draw-side toggle (decoration layers only): fills the row's
    // remaining space after Delete - the label carries the state
    // ("Back" draws before the base, "Front" over it).
    if (behind) |current_behind| {
        const behind_rect: Rectangle = .{
            .x = delete_rect.x + delete_rect.width + ui_gap,
            .y = control_rect.y,
            .width = control_rect.x + control_rect.width - (delete_rect.x + delete_rect.width + ui_gap),
            .height = control_rect.height,
        };
        try emitInspectorLayerButton(
            elements,
            allocator,
            font_metrics,
            behind_rect,
            if (current_behind) "Back" else "Front",
            .toggle_editor_decoration_layer_behind,
            layer_index,
            button_color,
            active_theme.lightest,
        );
    }
}

/// A panel-backed layer button with a centered label (Delete / Pick
/// sprite) carrying the layer-index payload - `emitInspectorSlotButton`'s
/// visual class (null layer index = the add-layer button).
pub fn emitInspectorLayerButton(
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
        .payload = .{ .editor_layer = layer_index },
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
/// slot's current skill (or "None") - clicking opens the centered skill
/// picker for that slot.
/// The utility-skill bar as ONE row of five 128×128 skill slots - the
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
                .payload = .{ .editor_utility_slot = slot_index },
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
            // Empty slot - the diamond marker (the skill-bar look); the
            // tooltip names the pick target.
            try elements.append(allocator, .{ .button = .{
                .sprite_id = "ui/skill_slot_empty",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .open_editor_skill_picker,
                .payload = .{ .editor_utility_slot = slot_index },
                .color = skill_frame_color,
                .tooltip = .{ .header = try spanRow(allocator, text("None")) },
            } });
        }
    }
}

/// M2 press arbitration for a focused text field (see DESIGN → UI
/// Framework → Text input widget): true when a left press may PROCEED
/// after committing the field - the press is on a sibling control of the
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
        // the close button): the picker is the ACTIVE interaction - commit
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

/// All inspector sections expanded - the content tests' standard state
/// (the shipped default is ALL COLLAPSED; see
/// `UiState.editor_inspector_section_expanded`). Pub for the main.zig
/// focus-on-click test, which builds the inspector through the real view.
pub fn allInspectorSectionsExpanded() [editor_inspector_section_count]bool {
    return .{true} ** editor_inspector_section_count;
}

/// Census panel driver for `buildEditorInspectorPanel` (the shared census
/// helper's duck-typed panel): builds at a scroll offset and reports the
/// builder's own clamp (it mutates `ui_state`).
const InspectorPanel = struct {
    arena: std.mem.Allocator,
    metrics: FontMetrics,
    editor: types.Editor,
    theme: types.ActiveColorTheme,
    open: bool = true,
    sections_expanded: bool = true,
    selected_inventory_slot: ?u32 = null,

    /// pub for the UI-census structure tests (the only cross-file caller).
    pub fn buildAt(self: InspectorPanel, scroll: i32, elements: *UiElementList) anyerror!i32 {
        var ui_state: UiState = .{
            .editor_inspector_scroll = scroll,
            .editor_inspector_section_expanded = if (self.sections_expanded)
                allInspectorSectionsExpanded()
            else
                .{false} ** editor_inspector_section_count,
            .editor_inventory_selected_slot = self.selected_inventory_slot,
        };
        try buildEditorInspectorPanel(
            elements,
            self.arena,
            self.metrics,
            self.editor,
            self.theme,
            self.open,
            &ui_state,
        );
        return ui_state.editor_inspector_scroll;
    }
};

/// Census panel driver for `buildEditorMetadataSidebar` (the same shape as
/// `InspectorPanel`; the sidebar scrolls `editor_metadata_scroll`).
const MetadataSidebarPanel = struct {
    arena: std.mem.Allocator,
    metrics: FontMetrics,
    editor: types.Editor,
    theme: types.ActiveColorTheme,
    definitions: types.ColorThemeDefinitions,
    open: bool = true,
    sections_expanded: bool = true,

    pub fn buildAt(self: MetadataSidebarPanel, scroll: i32, elements: *UiElementList) anyerror!i32 {
        var ui_state: UiState = .{
            .editor_metadata_scroll = scroll,
            .editor_inspector_section_expanded = if (self.sections_expanded)
                allInspectorSectionsExpanded()
            else
                .{false} ** editor_inspector_section_count,
        };
        try buildEditorMetadataSidebar(
            elements,
            self.arena,
            self.metrics,
            self.editor,
            self.theme,
            self.definitions,
            self.open,
            &ui_state,
        );
        return ui_state.editor_metadata_scroll;
    }
};

/// The scrollbar's track + thumb rects (the shared scrollbar grays) -
/// presence means the builder judged the content as overflowing the
/// window.
fn countScrollbarRects(elements: *const UiElementList) usize {
    var count: usize = 0;
    for (elements.items) |element| switch (element) {
        .solid_rect => |rect| {
            if (std.meta.eql(rect.color, ui_element.scrollbar_track_color) or
                std.meta.eql(rect.color, ui_element.scrollbar_thumb_color))
            {
                count += 1;
            }
        },
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
    // The toggle is self-explanatory (its label says what it does) - no
    // tooltip by design.
    try std.testing.expect(button.tooltip == null);

    const label = elements.items[2].text_label;
    try std.testing.expectEqualStrings("Inspector", label.text);
    try std.testing.expect(!label.blocks_input);
}

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
        // (literal 0,0,0 - the caret/selection follow the text color).
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
        // Selection spans buffer glyphs 8..10, caret sits at index 8 - the
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

    // Every scroll offset is scanned; each fact is asserted wherever it
    // is visible (the exhaustiveness shape - geometry is the input,
    // never the expectation; DESIGN → Testing → Assertion patterns).
    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    var stat_fields_seen = false;
    var team_value_seen = false;
    var swatch_row_seen = false;
    var toggle_seen = false;

    var scroll: i32 = 0;
    while (scroll <= max_scroll) : (scroll += 1) {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(scroll, &elements);

        // The Stats section's four numeric fields, decimal-formatted,
        // when the whole set is visible together.
        const max_health = findTextField(&elements, .{ .entity_stat = .max_health });
        const defense = findTextField(&elements, .{ .entity_stat = .defense });
        const speed = findTextField(&elements, .{ .entity_stat = .speed });
        const aggro_range = findTextField(&elements, .{ .entity_stat = .aggro_range });
        if (max_health != null and defense != null and speed != null and aggro_range != null) {
            try std.testing.expectEqualStrings("20", max_health.?.text);
            try std.testing.expectEqualStrings("0", defense.?.text);
            try std.testing.expectEqualStrings("1", speed.?.text);
            try std.testing.expectEqualStrings("3", aggro_range.?.text);
            stat_fields_seen = true;
        }

        // The Team field rides the same stat machinery: the template's
        // team, decimal-formatted.
        if (findTextField(&elements, .{ .entity_stat = .team })) |team_field| {
            try std.testing.expectEqualStrings("1", team_field.text);
            team_value_seen = true;
        }

        // The Color control: six swatch payload buttons in the ENEMY
        // gradient, the current index (2) the only highlighted one, the
        // gradient's index-2 fill present (the distinctive non-black).
        var swatch_count: usize = 0;
        var highlighted_count: usize = 0;
        var highlighted_color: ?u32 = null;
        var swatch_fill_seen = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_color) {
                swatch_count += 1;
                if (button.highlighted) {
                    highlighted_count += 1;
                    highlighted_color = button.payload.?.editor_color;
                }
            },
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, enemy_two)) swatch_fill_seen = true;
            },
            else => {},
        };
        if (swatch_count == types.gradient_color_count) {
            try std.testing.expectEqual(@as(usize, 1), highlighted_count);
            try std.testing.expectEqual(@as(u32, 2), highlighted_color.?);
            try std.testing.expect(swatch_fill_seen);
            swatch_row_seen = true;
        }

        // The Displays-weapons control: a half-width toggle showing the
        // FORMAT vocabulary ("true"), never highlighted (the label
        // carries the state).
        var toggle_button: ?Button = null;
        var true_label_seen = false;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .toggle_editor_entity_displays_weapons) toggle_button = button;
            },
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "true")) true_label_seen = true;
            },
            else => {},
        };
        if (toggle_button) |button| {
            try std.testing.expectEqual(
                @divFloor(editorInspectorPanelRect().width - 2 * ui_gap, 2),
                button.width,
            );
            try std.testing.expect(!button.highlighted);
            try std.testing.expect(true_label_seen);
            toggle_seen = true;
        }
    }

    try std.testing.expect(stat_fields_seen);
    try std.testing.expect(team_value_seen);
    try std.testing.expect(swatch_row_seen);
    try std.testing.expect(toggle_seen);
}

test "inspector sprite rows display custom namespaced stems as their file name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** types.gradient_color_count },
        .enemy_gradient = .{ .colors = .{black} ** types.gradient_color_count },
        .player_gradient = .{ .colors = .{black} ** types.gradient_color_count },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const entity_layers = [_]types.EntityLayer{.{
        .sprite = "custom/artists_den/hood",
        .color_index = 2,
    }};
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Boss",
        .template = .{
            .name = "Boss",
            .sprite = "custom/artists_den/boss",
            .team = 1,
            // Flag ON: custom art keeps its own colors - and the Color
            // row is hidden while it is (no dead tint control).
            .keep_original_colors = true,
            .layers = &entity_layers,
        },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // The display is a pure projection - the state keeps the full
    // namespaced stem (pick payloads + the level file carry the path).
    try std.testing.expectEqualStrings(
        "custom/artists_den/boss",
        editor.entity_types[0].template.sprite,
    );

    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    // The base-sprite row + the layer row show the FILE NAME. Flag ON: no
    // Color row + no swatch buttons at ANY offset (stronger than any
    // single window).
    var base_file_name_seen = false;
    var layer_file_name_seen = false;
    var color_label_seen = false;
    var swatch_button_seen = false;
    var scroll: i32 = 0;
    while (scroll <= max_scroll) : (scroll += 1) {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(scroll, &elements);
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "boss")) base_file_name_seen = true;
                if (std.mem.eql(u8, label.text, "hood")) layer_file_name_seen = true;
                if (std.mem.eql(u8, label.text, "Color")) color_label_seen = true;
            },
            .button => |button| {
                if (button.action == .select_editor_entity_color) swatch_button_seen = true;
            },
            else => {},
        };
    }
    try std.testing.expect(base_file_name_seen);
    try std.testing.expect(layer_file_name_seen);
    try std.testing.expect(!color_label_seen);
    try std.testing.expect(!swatch_button_seen);

    // Same rule for a decoration: flag ON hides the Color row + the
    // world-gradient swatch buttons.
    {
        const decoration_types = [_]types.DecorationTypeDef{.{
            .id = "custom/artists_den/banner",
            .sprite = "custom/artists_den/banner",
            .pixel_dims = .{ .x = 512, .y = 512 },
            .keep_original_colors = true,
        }};
        const decoration_editor: types.Editor = .{
            .decoration_types = &decoration_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        const decoration_panel = InspectorPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = decoration_editor,
            .theme = theme,
        };
        const decoration_max = try census.maxScroll(decoration_panel);
        var banner_seen = false;
        var decoration_swatch_seen = false;
        var decoration_scroll: i32 = 0;
        while (decoration_scroll <= decoration_max) : (decoration_scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try decoration_panel.buildAt(decoration_scroll, &elements);
            for (elements.items) |element| switch (element) {
                .text_label => |label| {
                    if (std.mem.eql(u8, label.text, "banner")) banner_seen = true;
                },
                .button => |button| {
                    if (button.action == .select_editor_decoration_color) decoration_swatch_seen = true;
                },
                else => {},
            };
        }
        try std.testing.expect(banner_seen);
        try std.testing.expect(!decoration_swatch_seen);
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

    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    // The sprite button opens the shared picker (the input site routes
    // the kind by the inspector target). The Color control: six swatch
    // payload buttons in the WORLD gradient, the current index (3) the
    // only highlighted one, its fill present. The Footprint row's tile
    // count is reachable somewhere. Each fact asserted wherever visible.
    var sprite_button_seen = false;
    var swatch_row_seen = false;
    var footprint_count_seen = false;
    var scroll: i32 = 0;
    while (scroll <= max_scroll) : (scroll += 1) {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(scroll, &elements);
        var swatch_count: usize = 0;
        var highlighted_count: usize = 0;
        var highlighted_color: ?u32 = null;
        var world_fill_seen = false;
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "2 tiles")) footprint_count_seen = true;
            },
            .button => |button| {
                if (button.action == .open_editor_sprite_picker) sprite_button_seen = true;
                if (button.action == .select_editor_decoration_color) {
                    swatch_count += 1;
                    if (button.highlighted) {
                        highlighted_count += 1;
                        highlighted_color = button.payload.?.editor_color;
                    }
                }
            },
            .solid_rect => |rect| {
                // The WORLD gradient's index-3 color is the swatch fill for
                // index 3 (the others are black - assert the distinctive one).
                if (std.meta.eql(rect.color, world_three)) world_fill_seen = true;
            },
            else => {},
        };
        if (swatch_count == types.gradient_color_count) {
            try std.testing.expectEqual(@as(usize, 1), highlighted_count);
            try std.testing.expectEqual(@as(u32, 3), highlighted_color.?);
            try std.testing.expect(world_fill_seen);
            swatch_row_seen = true;
        }
    }
    try std.testing.expect(sprite_button_seen);
    try std.testing.expect(swatch_row_seen);
    try std.testing.expect(footprint_count_seen);
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

    const weapon_type_count = @typeInfo(types.WeaponType).@"enum".fields.len;

    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    // Main hand: an equipped sword → type row + Delete + its fields.
    // Off hand: empty → type row + Add, never fields. Gear: coat
    // equipped → Delete + fields; amulet empty → Add, never fields. Each
    // fact asserted wherever visible; the empty slots' fields must
    // NEVER appear at any offset.
    var main_hand_fields_seen = false;
    var main_hand_type_row_seen = false;
    var off_hand_type_row_seen = false;
    var off_hand_fields_seen = false;
    var amulet_add_seen = false;
    var coat_delete_seen = false;
    var coat_fields_seen = false;
    var amulet_name_seen = false;

    var scroll: i32 = 0;
    while (scroll <= max_scroll) : (scroll += 1) {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(scroll, &elements);

        // The equipped weapon's fields carry its values (the pair is
        // adjacent 1-unit rows - gate on both so a window edge between
        // them doesn't false-fail).
        const main_hand_name = findTextField(&elements, .{ .item_name = .main_hand });
        const main_hand_damage = findTextField(&elements, .{ .item_stat = .{ .slot = .main_hand, .stat = .weapon_damage } });
        if (main_hand_name != null and main_hand_damage != null) {
            try std.testing.expectEqualStrings("Skeleton Sword", main_hand_name.?.text);
            try std.testing.expectEqualStrings("5", main_hand_damage.?.text);
            main_hand_fields_seen = true;
        }
        if (findTextField(&elements, .{ .item_name = .off_hand }) != null) {
            off_hand_fields_seen = true;
        }

        // Type cells: one full row per hand - the main hand's carries the
        // highlighted sword + a Delete; the off hand's carries neither.
        var main_hand_cells: usize = 0;
        var main_hand_highlighted: ?types.WeaponType = null;
        var main_hand_deletes: usize = 0;
        var off_hand_cells: usize = 0;
        var off_hand_highlight_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .select_editor_weapon_type) {
                    const cell = button.payload.?.editor_weapon_type_cell;
                    switch (cell.gear_slot) {
                        .main_hand => {
                            main_hand_cells += 1;
                            if (button.highlighted) main_hand_highlighted = cell.weapon_type;
                        },
                        .off_hand => {
                            off_hand_cells += 1;
                            if (button.highlighted) off_hand_highlight_count += 1;
                        },
                        else => {},
                    }
                }
                if (button.action == .delete_editor_item and button.payload.?.editor_gear_slot == .main_hand) {
                    main_hand_deletes += 1;
                }
                if (button.action == .add_editor_item and button.payload.?.editor_gear_slot == .amulet) amulet_add_seen = true;
                if (button.action == .delete_editor_item and button.payload.?.editor_gear_slot == .coat) coat_delete_seen = true;
            },
            else => {},
        };
        if (main_hand_cells == weapon_type_count) {
            try std.testing.expectEqual(types.WeaponType.sword, main_hand_highlighted.?);
            try std.testing.expectEqual(@as(usize, 1), main_hand_deletes);
            main_hand_type_row_seen = true;
        }
        if (off_hand_cells == weapon_type_count) {
            try std.testing.expectEqual(@as(usize, 0), off_hand_highlight_count);
            off_hand_type_row_seen = true;
        }

        // The equipped coat's fields carry its values; the empty amulet
        // never has any.
        const coat_name = findTextField(&elements, .{ .item_name = .coat });
        const coat_health = findTextField(&elements, .{ .item_stat = .{ .slot = .coat, .stat = .health_bonus } });
        if (coat_name != null and coat_health != null) {
            try std.testing.expectEqualStrings("Skeleton Coat", coat_name.?.text);
            try std.testing.expectEqualStrings("2", coat_health.?.text);
            coat_fields_seen = true;
        }
        if (findTextField(&elements, .{ .item_name = .amulet }) != null) {
            amulet_name_seen = true;
        }
    }

    try std.testing.expect(main_hand_fields_seen);
    try std.testing.expect(main_hand_type_row_seen);
    try std.testing.expect(off_hand_type_row_seen);
    try std.testing.expect(!off_hand_fields_seen);
    try std.testing.expect(amulet_add_seen);
    try std.testing.expect(coat_delete_seen);
    try std.testing.expect(coat_fields_seen);
    try std.testing.expect(!amulet_name_seen);
}

test "editorInspectorTarget: active entity/decoration/item tools pass through; tile falls back to the player" {
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
    // (legitimately uninspectable - they contribute nothing) → still that
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
    // unresolvable bug-state reference - fallback, not a crash (the
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
    // unresolvable bug-state reference - fallback, not a crash (the
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

    const type_cell_count = @typeInfo(types.WeaponType).@"enum".fields.len +
        @typeInfo(types.ItemKind).@"enum".fields.len - 1;

    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    // The name + stat fields: current values + the `.item_type` ref
    // targets. The type rows: one cell per weapon type + one per gear
    // kind, the sword cell (the current item) the only highlighted one;
    // weapon cells carry the weapon-type payload, gear cells don't. Each
    // fact asserted wherever visible.
    var name_field_seen = false;
    var damage_field_seen = false;
    var type_rows_seen = false;

    var scroll: i32 = 0;
    while (scroll <= max_scroll) : (scroll += 1) {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(scroll, &elements);

        if (findTextField(&elements, .item_def_name)) |name_field| {
            try std.testing.expectEqualStrings("Iron Sword", name_field.text);
            try std.testing.expectEqual(
                types.TextFieldRef{ .id = .item_def_name, .target = .{ .item_type = 0 } },
                name_field.ref,
            );
            name_field_seen = true;
        }
        if (findTextField(&elements, .{ .item_def_stat = .weapon_damage })) |damage_field| {
            try std.testing.expectEqualStrings("5", damage_field.text);
            try std.testing.expectEqual(
                types.TextFieldRef{ .id = .{ .item_def_stat = .weapon_damage }, .target = .{ .item_type = 0 } },
                damage_field.ref,
            );
            damage_field_seen = true;
        }

        var pick_cells: usize = 0;
        var highlighted_kinds: usize = 0;
        var sword_icons: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_item_type) {
                pick_cells += 1;
                const cell = button.payload.?.editor_item_kind_cell;
                if (cell.kind == .weapon) {
                    try std.testing.expect(cell.weapon_type != null);
                    if (button.highlighted) {
                        highlighted_kinds += 1;
                        try std.testing.expectEqual(types.WeaponType.sword, cell.weapon_type.?);
                    }
                } else {
                    try std.testing.expect(cell.weapon_type == null);
                    try std.testing.expect(!button.highlighted);
                }
            },
            .image => |image| {
                if (std.mem.eql(u8, image.sprite_id, "items/sword")) sword_icons += 1;
            },
            else => {},
        };
        if (pick_cells == type_cell_count) {
            try std.testing.expectEqual(@as(usize, 1), highlighted_kinds);
            try std.testing.expectEqual(@as(usize, 1), sword_icons);
            type_rows_seen = true;
        }
    }
    try std.testing.expect(name_field_seen);
    try std.testing.expect(damage_field_seen);
    try std.testing.expect(type_rows_seen);
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

    // A coat (two stats) - the field set follows the kind; a stat the
    // kind doesn't carry is never offered at any offset.
    {
        const item_types = [_]types.ItemTypeDef{.{
            .id = "Leather Coat",
            .item = .{ .coat = .{ .name = "Leather Coat", .health_bonus = 3, .defense_bonus = 2 } },
        }};
        const editor: types.Editor = .{
            .item_types = &item_types,
            .active_tool = .{ .item_type = 0 },
        };
        const panel = InspectorPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = editor,
            .theme = theme,
        };
        const max_scroll = try census.maxScroll(panel);
        var name_seen = false;
        var health_seen = false;
        var defense_seen = false;
        var weapon_damage_seen = false;
        var scroll: i32 = 0;
        while (scroll <= max_scroll) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try panel.buildAt(scroll, &elements);
            if (findTextField(&elements, .item_def_name)) |name_field| {
                try std.testing.expectEqualStrings("Leather Coat", name_field.text);
                name_seen = true;
            }
            if (findTextField(&elements, .{ .item_def_stat = .health_bonus })) |health_field| {
                try std.testing.expectEqualStrings("3", health_field.text);
                health_seen = true;
            }
            if (findTextField(&elements, .{ .item_def_stat = .defense_bonus })) |defense_field| {
                try std.testing.expectEqualStrings("2", defense_field.text);
                defense_seen = true;
            }
            if (findTextField(&elements, .{ .item_def_stat = .weapon_damage }) != null) {
                weapon_damage_seen = true;
            }
        }
        try std.testing.expect(name_seen);
        try std.testing.expect(health_seen);
        try std.testing.expect(defense_seen);
        try std.testing.expect(!weapon_damage_seen);
    }

    // A skill tome (unreachable live - not authorable): no name field, no
    // stat fields at any offset, but the type rows still render.
    {
        const item_types = [_]types.ItemTypeDef{.{
            .id = "Skill Tome",
            .item = .{ .skill_tome = .{ .skill = .slice, .value = 5 } },
        }};
        const editor: types.Editor = .{
            .item_types = &item_types,
            .active_tool = .{ .item_type = 0 },
        };
        const type_cell_count = @typeInfo(types.WeaponType).@"enum".fields.len +
            @typeInfo(types.ItemKind).@"enum".fields.len - 1;
        const panel = InspectorPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = editor,
            .theme = theme,
        };
        const max_scroll = try census.maxScroll(panel);
        var name_field_seen = false;
        var type_rows_seen = false;
        var scroll: i32 = 0;
        while (scroll <= max_scroll) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try panel.buildAt(scroll, &elements);
            if (findTextField(&elements, .item_def_name) != null) name_field_seen = true;
            var pick_cells: usize = 0;
            for (elements.items) |element| switch (element) {
                .button => |button| {
                    if (button.action == .select_editor_item_type) pick_cells += 1;
                },
                else => {},
            };
            if (pick_cells == type_cell_count) type_rows_seen = true;
        }
        try std.testing.expect(!name_field_seen);
        try std.testing.expect(type_rows_seen);
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
    // interaction - the press proceeds (commit + pick in one click).
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
    // content (the fallback target) - ALL SECTIONS COLLAPSED by default:
    // five headers (+ markers) + spacers, everything fits, no scrollbar.
    const editor: types.Editor = .{};

    // Open (the default): the toggle trio + background panel + five
    // collapsed section strips. The exhaustive census over the single
    // window (all-collapsed content fits - max scroll 0) pins the exact
    // ordered content.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        // toggle 3 + background 1 + one strip (panel + button + label)
        // per section header.
        try std.testing.expectEqual(@as(usize, 4 + 3 * 5), elements.items.len);
        try expectInspectorToggleShape(&elements);
        try census.expectContentReachable(
            arena.allocator(),
            InspectorPanel{ .arena = arena.allocator(), .metrics = metrics, .editor = editor, .theme = theme, .sections_expanded = false },
            &.{ "Inspector", "+ Player", "+ Weapons", "+ Gear", "+ Utility skills", "+ Inventory" },
        );
        // The player content tints with the PLAYER gradient (the strip at
        // element 4 uses gradient[5]).
        try std.testing.expectEqual(player_five, elements.items[4].nine_slice_panel.color);

        // The background panel: flush left, below the button, down to one
        // ui_gap above the expanded palette groups' header strip, tinted
        // darkest (the background-panel class - button panels tint
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
        // The builder draws exactly the shared rect fn - the M2 press
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

test "buildEditorInspectorPanel content: entity tool rows windowed + clamped, scrollbar on overflow" {
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

    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    // Overflow: the entity content is taller than the window, so a
    // scroll range exists and the scrollbar (track + thumb) is emitted.
    try std.testing.expect(max_scroll > 0);
    {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(0, &elements);
        try std.testing.expectEqual(@as(usize, 2), countScrollbarRects(&elements));
    }

    // THE exhaustive census: every window's labels are an ordered subset
    // of the full content list, and the union of all windows covers it
    // completely - no never-emitted row, no unreachable row. The list is
    // the panel's semantic content contract, NOT a window snapshot.
    try census.expectContentReachable(arena.allocator(), panel, &.{
        "Inspector",        "- Identity",  "Name",
        "Team",             "Sprite",      "(none)",
        "Keep colors",      "false",       "Color",
        "Displays weapons", "true",        "- Stats",
        "Max health",       "Defense",     "Speed",
        "Aggro range",      "- Weapons",   "Main hand",
        "Off hand",         "- Gear",      "Amulet",
        "Add",              "Coat",        "Add",
        "Gloves",           "Add",         "Pants",
        "Add",              "Boots",       "Add",
        "- Utility skills", "Skill bar",   "- Layers",
        "Add layer",        "Pick sprite",
    });

    // Clamp semantics: negative clamps to 0; the max-clamped window
    // still shows content (the tail, never an empty window).
    {
        var elements: UiElementList = .empty;
        try std.testing.expectEqual(@as(i32, 0), try panel.buildAt(-4, &elements));
    }
    {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(max_scroll, &elements);
        var label_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .text_label => label_count += 1,
            else => {},
        };
        try std.testing.expect(label_count > 0);
    }

    // The skill row: five picker slots (utility_skill_count), all empty
    // diamonds for this unequipped template - asserted wherever the
    // row is fully visible.
    {
        var skill_row_seen = false;
        var scroll: i32 = 0;
        while (scroll <= max_scroll) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try panel.buildAt(scroll, &elements);
            var picker_buttons: usize = 0;
            var all_diamonds = true;
            for (elements.items) |element| switch (element) {
                .button => |button| if (button.action == .open_editor_skill_picker) {
                    picker_buttons += 1;
                    if (!std.mem.eql(u8, button.sprite_id.?, "ui/skill_slot_empty")) all_diamonds = false;
                },
                else => {},
            };
            if (picker_buttons == types.utility_skill_count) {
                try std.testing.expect(all_diamonds);
                skill_row_seen = true;
            }
        }
        try std.testing.expect(skill_row_seen);
    }

    // A stale tool id (the type deleted mid-edit) falls back to the
    // PLAYER content: the full slot grid is reachable - every inventory
    // slot button appears at some offset.
    {
        const stale_editor: types.Editor = .{
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 7 },
        };
        const stale_panel = InspectorPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = stale_editor,
            .theme = theme,
        };
        const stale_max = try census.maxScroll(stale_panel);
        try std.testing.expect(stale_max > 0);
        var slot_seen = [_]bool{false} ** types.inventory_slot_count;
        var scroll: i32 = 0;
        while (scroll <= stale_max) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try stale_panel.buildAt(scroll, &elements);
            for (elements.items) |element| switch (element) {
                .button => |button| if (button.action == .select_editor_inventory_slot) {
                    slot_seen[button.payload.?.editor_inventory_slot] = true;
                },
                else => {},
            };
        }
        for (slot_seen) |seen| try std.testing.expect(seen);
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

    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    // Wherever the skill row is fully visible: five picker buttons
    // (utility_skill_count) - blink's slot is the skill button, the rest
    // the empty diamond, every slot riding its index; the occupied slot
    // carries the full-size skill icon; the cells pitch row height +
    // ui_gap.
    var skill_row_seen = false;
    var scroll: i32 = 0;
    while (scroll <= max_scroll) : (scroll += 1) {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(scroll, &elements);

        var slot_buttons: usize = 0;
        var blink_slot: ?u32 = null;
        var saw_blink_icon = false;
        var previous_x: ?i32 = null;
        var pitches: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .open_editor_skill_picker) {
                slot_buttons += 1;
                if (button.payload.?.editor_utility_slot == 1) {
                    try std.testing.expectEqualStrings("ui/skill_button", button.sprite_id.?);
                    blink_slot = button.payload.?.editor_utility_slot;
                } else {
                    try std.testing.expectEqualStrings("ui/skill_slot_empty", button.sprite_id.?);
                }
                if (previous_x) |x| {
                    try std.testing.expectEqual(editor_inspector_row_height + ui_gap, button.screen_position.x - x);
                    pitches += 1;
                }
                previous_x = button.screen_position.x;
            },
            .image => |image| if (std.mem.eql(u8, image.sprite_id, skillIconSpriteId(.blink))) {
                saw_blink_icon = true;
                try std.testing.expectEqual(@as(i32, 128), image.width);
                try std.testing.expectEqual(@as(i32, 128), image.height);
            },
            else => {},
        };
        if (slot_buttons == types.utility_skill_count) {
            try std.testing.expectEqual(@as(?u32, 1), blink_slot);
            try std.testing.expect(saw_blink_icon);
            try std.testing.expectEqual(@as(usize, types.utility_skill_count - 1), pitches);
            skill_row_seen = true;
        }
    }
    try std.testing.expect(skill_row_seen);
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

    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    // The equipped main hand's fields carry `.player_def` - the player
    // content's commits route there - and the equipped hand shows its
    // Delete (not Add). The Import row renders BOTH buttons - Player
    // data (the session import) and Max player (the shipped max
    // loadout). The skill row: blink occupied in slot 0, the rest
    // diamonds. The inventory grid's first row: the two equipped items
    // (slots 3 + 4) render their icon overlays. Each fact asserted
    // wherever visible.
    var main_hand_fields_seen = false;
    var main_hand_delete_seen = false;
    var import_buttons_seen = false;
    var skill_row_seen = false;
    var inventory_first_row_seen = false;

    var scroll: i32 = 0;
    while (scroll <= max_scroll) : (scroll += 1) {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(scroll, &elements);

        const main_hand_name = findTextField(&elements, .{ .item_name = .main_hand });
        const main_hand_damage = findTextField(&elements, .{ .item_stat = .{ .slot = .main_hand, .stat = .weapon_damage } });
        if (main_hand_name != null and main_hand_damage != null) {
            try std.testing.expectEqualStrings("Starter Sword", main_hand_name.?.text);
            try std.testing.expectEqual(types.TextEditTarget{ .entity = .player_def }, main_hand_name.?.ref.target);
            try std.testing.expectEqualStrings("3", main_hand_damage.?.text);
            try std.testing.expectEqual(types.TextEditTarget{ .entity = .player_def }, main_hand_damage.?.ref.target);
            main_hand_fields_seen = true;
        }

        var player_data_button = false;
        var max_player_button = false;
        var main_hand_delete = false;
        var picker_buttons: usize = 0;
        var blink_occupied = false;
        var first_row_cells: usize = 0;
        var icon_overlays: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .import_editor_player) player_data_button = true;
                if (button.action == .import_editor_max_player) max_player_button = true;
                if (button.action == .delete_editor_item and
                    button.payload.?.editor_gear_slot == .main_hand)
                {
                    main_hand_delete = true;
                }
                if (button.action == .open_editor_skill_picker) {
                    picker_buttons += 1;
                    if (button.payload.?.editor_utility_slot == 0) {
                        try std.testing.expectEqualStrings("ui/skill_button", button.sprite_id.?);
                        blink_occupied = true;
                    } else {
                        try std.testing.expectEqualStrings("ui/skill_slot_empty", button.sprite_id.?);
                    }
                }
                if (button.action == .select_editor_inventory_slot and
                    button.payload.?.editor_inventory_slot < editor_inventory_slots_per_row)
                {
                    first_row_cells += 1;
                }
            },
            .image => |image| {
                if (std.mem.startsWith(u8, image.sprite_id, "items/")) icon_overlays += 1;
            },
            else => {},
        };
        if (player_data_button and max_player_button) import_buttons_seen = true;
        if (main_hand_delete) main_hand_delete_seen = true;
        if (picker_buttons == types.utility_skill_count) {
            try std.testing.expect(blink_occupied);
            skill_row_seen = true;
        }
        // The grid's first row fully visible → its two occupied cells'
        // icon overlays (the only items/ images in this content).
        if (first_row_cells == editor_inventory_slots_per_row) {
            try std.testing.expectEqual(@as(usize, 2), icon_overlays);
            inventory_first_row_seen = true;
        }
    }

    try std.testing.expect(main_hand_fields_seen);
    try std.testing.expect(main_hand_delete_seen);
    try std.testing.expect(import_buttons_seen);
    try std.testing.expect(skill_row_seen);
    try std.testing.expect(inventory_first_row_seen);
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

    // ENEMY content with one layer: the layer row (sprite re-pick +
    // delete, both carrying the layer index) + the color row's swatches
    // are reachable; the current color index (2) is the only highlighted
    // swatch. Facts asserted wherever visible.
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
        const panel = InspectorPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = editor,
            .theme = theme,
        };
        const max_scroll = try census.maxScroll(panel);

        var stem_button_seen = false;
        var delete_button_seen = false;
        var swatch_row_seen = false;
        var layer_labels_seen = false;
        var scroll: i32 = 0;
        while (scroll <= max_scroll) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try panel.buildAt(scroll, &elements);
            var saw_layer_label = false;
            var saw_hood_label = false;
            var swatch_count: usize = 0;
            var highlighted_count: usize = 0;
            for (elements.items) |element| switch (element) {
                .text_label => |label| {
                    if (std.mem.eql(u8, label.text, "Layer 1")) saw_layer_label = true;
                    if (std.mem.eql(u8, label.text, "hood")) saw_hood_label = true;
                },
                .button => |button| {
                    if (button.action == .open_editor_entity_layer_picker and
                        button.payload.?.editor_layer != null and button.payload.?.editor_layer.? == 0)
                    {
                        stem_button_seen = true;
                    }
                    if (button.action == .delete_editor_entity_layer and
                        button.payload.?.editor_layer != null and button.payload.?.editor_layer.? == 0)
                    {
                        delete_button_seen = true;
                    }
                    if (button.action == .select_editor_entity_layer_color) {
                        try std.testing.expectEqual(@as(u32, 0), button.payload.?.editor_layer_color.layer_index);
                        swatch_count += 1;
                        if (button.highlighted) highlighted_count += 1;
                    }
                },
                else => {},
            };
            if (swatch_count == types.gradient_color_count) {
                try std.testing.expectEqual(@as(usize, 1), highlighted_count);
                swatch_row_seen = true;
            }
            if (saw_layer_label and saw_hood_label) layer_labels_seen = true;
        }
        try std.testing.expect(stem_button_seen);
        try std.testing.expect(delete_button_seen);
        try std.testing.expect(swatch_row_seen);
        try std.testing.expect(layer_labels_seen);
    }

    // DECORATION content with one layer: the color row's swatches carry
    // the layer index (world-gradient swatches).
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
        const panel = InspectorPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = editor,
            .theme = theme,
        };
        const max_scroll = try census.maxScroll(panel);
        var swatch_row_seen = false;
        var scroll: i32 = 0;
        while (scroll <= max_scroll) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try panel.buildAt(scroll, &elements);
            var swatch_count: usize = 0;
            for (elements.items) |element| switch (element) {
                .button => |button| if (button.action == .select_editor_decoration_layer_color) {
                    try std.testing.expectEqual(@as(u32, 0), button.payload.?.editor_layer_color.layer_index);
                    swatch_count += 1;
                },
                else => {},
            };
            if (swatch_count == types.gradient_color_count) swatch_row_seen = true;
        }
        try std.testing.expect(swatch_row_seen);
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
    // The definitions the gradient rows' derived indices come from: 3
    // gradients, the active level's wheel index 0 - world 0, enemy
    // AUTO-derives to 1 (0 + 3/3), player is MANUAL at 2.
    const gradients = [_]types.ColorGradient{
        .{ .colors = .{black} ** 6 },
        .{ .colors = .{black} ** 6 },
        .{ .colors = .{black} ** 6 },
    };
    const definitions: types.ColorThemeDefinitions = .{
        .lightest = lightest,
        .darkest = black,
        .gradients = &gradients,
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
        try buildEditorMetadataSidebar(&elements, arena.allocator(), metrics, editor, theme, definitions, false, &ui_state);
        try std.testing.expectEqual(@as(usize, 3), elements.items.len);
        try std.testing.expectEqual(Action.toggle_editor_metadata_sidebar, elements.items[1].button.action);
        const toggle_panel = elements.items[0].nine_slice_panel;
        try std.testing.expectEqual(top_bar_height + ui_gap, toggle_panel.screen_position.y);
        try std.testing.expectEqual(types.reference_width, toggle_panel.screen_position.x + toggle_panel.width);
    }

    // Open + COLLAPSED (the default): the background panel + two section
    // headers only - the inspector's all-collapsed convention.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorMetadataSidebar(&elements, arena.allocator(), metrics, editor, theme, definitions, true, &ui_state);
        // The strips are the shared collapsible headers (+ marker, the
        // toggle action, the section id payload).
        var headers: [2]?Button = .{ null, null };
        var headers_seen: [2]bool = .{ false, false };
        for (elements.items) |element| switch (element) {
            .button => |button| switch (button.action) {
                .toggle_editor_inspector_section => switch (button.payload.?.editor_section) {
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

    // Open + EXPANDED: the entries window like the inspector's. The
    // exhaustive census over every scroll offset pins the content list
    // (the sidebar's semantic content contract, not a window snapshot).
    {
        const panel = MetadataSidebarPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = editor,
            .theme = theme,
            .definitions = definitions,
        };
        try census.expectContentReachable(arena.allocator(), panel, &.{
            "Metadata", "- Mission", "Name", "- Current level", "Name",
            "World colors", "0", "Enemy colors", "1", "Auto",
            "Player colors", "2", "Auto",
        });
        const max_scroll = try census.maxScroll(panel);
        try std.testing.expect(max_scroll > 0);

        // The semantic facts, asserted wherever visible: the mission +
        // level name fields' values + targets; the WORLD swatch ALWAYS
        // outlined (its index is always an explicit pick - no Auto state
        // to carry the outline instead); the outline marks the mode on
        // the enemy (auto) + player (manual, override 2) rows; the
        // scrollbar (track + thumb) present while overflowing.
        var mission_field_seen = false;
        var level_field_seen = false;
        var world_button_seen = false;
        var enemy_row_mode_seen = false;
        var player_row_mode_seen = false;
        var scrollbar_seen = false;
        // The gradient rows' index numbers, one seen-flag per role
        // (world/enemy/player) - the association check fires wherever a
        // row's label line is visible.
        var gradient_number_seen: [3]bool = .{ false, false, false };
        var scroll: i32 = 0;
        while (scroll <= max_scroll) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try panel.buildAt(scroll, &elements);
            if (countScrollbarRects(&elements) == 2) scrollbar_seen = true;

            var mission_field: ?TextFieldUi = null;
            var level_field: ?TextFieldUi = null;
            var world_button: ?Button = null;
            var enemy_auto_button: ?Button = null;
            var enemy_swatch_button: ?Button = null;
            var player_auto_button: ?Button = null;
            var player_swatch_button: ?Button = null;
            var role_label_y: [3]?i32 = .{ null, null, null };
            var number_values: [3]u32 = undefined;
            var number_ys: [3]i32 = undefined;
            var numbers_seen: usize = 0;
            for (elements.items) |element| switch (element) {
                .text_label => |label| {
                    if (std.mem.eql(u8, label.text, "World colors")) role_label_y[0] = label.screen_position.y;
                    if (std.mem.eql(u8, label.text, "Enemy colors")) role_label_y[1] = label.screen_position.y;
                    if (std.mem.eql(u8, label.text, "Player colors")) role_label_y[2] = label.screen_position.y;
                    if ((std.fmt.parseInt(u32, label.text, 10) catch null)) |number| {
                        if (numbers_seen < number_values.len) {
                            number_values[numbers_seen] = number;
                            number_ys[numbers_seen] = label.screen_position.y;
                            numbers_seen += 1;
                        }
                    }
                },
                .text_field => |field| switch (field.ref.id) {
                    .mission_name => mission_field = field,
                    .level_name => level_field = field,
                    else => {},
                },
                .button => |button| switch (button.action) {
                    .open_editor_level_gradient_picker => switch (button.payload.?.editor_gradient_role) {
                        .world => world_button = button,
                        .enemy => enemy_swatch_button = button,
                        .player => player_swatch_button = button,
                    },
                    .toggle_editor_level_gradient_auto => switch (button.payload.?.editor_gradient_role) {
                        .enemy => enemy_auto_button = button,
                        .player => player_auto_button = button,
                        else => {},
                    },
                    else => {},
                },
                else => {},
            };
            if (mission_field) |field| {
                try std.testing.expectEqualStrings("My Mission", field.text);
                try std.testing.expectEqual(types.TextEditTarget.mission, field.ref.target);
                mission_field_seen = true;
            }
            if (level_field) |field| {
                try std.testing.expectEqualStrings("Second", field.text);
                try std.testing.expectEqual(types.TextEditTarget{ .level = 1 }, field.ref.target);
                level_field_seen = true;
            }
            if (world_button) |button| {
                try std.testing.expect(button.highlighted);
                world_button_seen = true;
            }
            if (enemy_auto_button != null and enemy_swatch_button != null) {
                try std.testing.expect(enemy_auto_button.?.highlighted);
                try std.testing.expect(!enemy_swatch_button.?.highlighted);
                enemy_row_mode_seen = true;
            }
            if (player_auto_button != null and player_swatch_button != null) {
                try std.testing.expect(!player_auto_button.?.highlighted);
                try std.testing.expect(player_swatch_button.?.highlighted);
                player_row_mode_seen = true;
            }

            // The gradient rows' index numbers: wherever a row's role
            // label line is visible, a number sits on the SAME line and
            // carries the semantic values - world 0, enemy AUTO-derived 1
            // (wheel 0 + 1 of 3), player MANUAL 2.
            const expected_indices = [_]u32{ 0, 1, 2 };
            for (role_label_y, 0..) |maybe_y, role_index| {
                const label_y = maybe_y orelse continue;
                var number_found = false;
                for (number_ys[0..numbers_seen], number_values[0..numbers_seen]) |number_y, number| {
                    if (number_y != label_y) continue;
                    number_found = true;
                    try std.testing.expectEqual(expected_indices[role_index], number);
                }
                try std.testing.expect(number_found);
                gradient_number_seen[role_index] = true;
            }
        }
        try std.testing.expect(mission_field_seen);
        try std.testing.expect(level_field_seen);
        try std.testing.expect(world_button_seen);
        try std.testing.expect(enemy_row_mode_seen);
        try std.testing.expect(player_row_mode_seen);
        for (gradient_number_seen) |seen| try std.testing.expect(seen);
        try std.testing.expect(scrollbar_seen);

        // Clamp semantics: an out-of-range scroll clamps to the content
        // max, and the max window shows the TAIL - the mission name
        // field (the topmost row) is windowed out there.
        var tail_elements: UiElementList = .empty;
        const clamped = try panel.buildAt(99, &tail_elements);
        try std.testing.expectEqual(max_scroll, clamped);
        var mission_field_in_tail = false;
        for (tail_elements.items) |element| switch (element) {
            .text_field => |field| {
                if (field.ref.id == .mission_name) mission_field_in_tail = true;
            },
            else => {},
        };
        try std.testing.expect(!mission_field_in_tail);
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

    const panel = InspectorPanel{
        .arena = arena.allocator(),
        .metrics = metrics,
        .editor = editor,
        .theme = theme,
    };
    const max_scroll = try census.maxScroll(panel);

    // No selection: bare slot rows only - the section header reachable,
    // and NO detail buttons at ANY offset (stronger than any single
    // window).
    {
        var detail_buttons: usize = 0;
        var inventory_header_seen = false;
        var scroll: i32 = 0;
        while (scroll <= max_scroll) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try panel.buildAt(scroll, &elements);
            for (elements.items) |element| switch (element) {
                .text_label => |label| {
                    if (std.mem.eql(u8, label.text, "- Inventory")) inventory_header_seen = true;
                },
                .button => |button| if (button.action == .add_editor_inventory_item or
                    button.action == .delete_editor_inventory_item or
                    button.action == .select_editor_inventory_item_type)
                {
                    detail_buttons += 1;
                },
                else => {},
            };
        }
        try std.testing.expectEqual(@as(usize, 0), detail_buttons);
        try std.testing.expect(inventory_header_seen);
    }

    // Selected OCCUPIED slot 4: the detail block inserts directly below
    // its slot row - Delete (not Add), the type rows (the amulet cell
    // highlighted), name + spell damage fields, all targeting slot 4;
    // the slot's own cell highlighted. Facts asserted wherever visible.
    {
        const selected_panel = InspectorPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = editor,
            .theme = theme,
            .selected_inventory_slot = 4,
        };
        const selected_max = try census.maxScroll(selected_panel);
        var detail_fields_seen = false;
        var slot_label_seen = false;
        var selected_cell_seen = false;
        var delete_button_seen = false;
        var amulet_cell_seen = false;
        var scroll: i32 = 0;
        while (scroll <= selected_max) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try selected_panel.buildAt(scroll, &elements);
            const detail_name = findTextField(&elements, .inventory_item_name);
            const detail_stat = findTextField(&elements, .{ .inventory_item_stat = .spell_damage });
            if (detail_name != null and detail_stat != null) {
                try std.testing.expectEqualStrings("Starter Amulet", detail_name.?.text);
                try std.testing.expectEqual(types.TextEditTarget{ .inventory_slot = 4 }, detail_name.?.ref.target);
                try std.testing.expectEqualStrings("3", detail_stat.?.text);
                detail_fields_seen = true;
            }
            for (elements.items) |element| switch (element) {
                .text_label => |label| {
                    if (std.mem.eql(u8, label.text, "Slot 5")) slot_label_seen = true;
                },
                .button => |button| {
                    if (button.action == .select_editor_inventory_slot and
                        button.payload.?.editor_inventory_slot == 4 and button.highlighted)
                    {
                        selected_cell_seen = true;
                    }
                    if (button.action == .delete_editor_inventory_item and
                        button.payload.?.editor_inventory_slot == 4)
                    {
                        delete_button_seen = true;
                    }
                    if (button.action == .select_editor_inventory_item_type and
                        button.payload.?.editor_item_kind_cell.kind == .amulet and button.highlighted)
                    {
                        amulet_cell_seen = true;
                    }
                },
                else => {},
            };
        }
        try std.testing.expect(detail_fields_seen);
        try std.testing.expect(slot_label_seen);
        try std.testing.expect(selected_cell_seen);
        try std.testing.expect(delete_button_seen);
        try std.testing.expect(amulet_cell_seen);
    }

    // Selected EMPTY slot 13: Add only - no type rows, no fields at ANY
    // offset (author decision: an empty slot shows Add until an item
    // exists).
    {
        const selected_panel = InspectorPanel{
            .arena = arena.allocator(),
            .metrics = metrics,
            .editor = editor,
            .theme = theme,
            .selected_inventory_slot = 13,
        };
        const selected_max = try census.maxScroll(selected_panel);
        var add_button_seen = false;
        var name_field_seen = false;
        var type_cells: usize = 0;
        var scroll: i32 = 0;
        while (scroll <= selected_max) : (scroll += 1) {
            var elements: UiElementList = .empty;
            _ = try selected_panel.buildAt(scroll, &elements);
            if (findTextField(&elements, .inventory_item_name) != null) name_field_seen = true;
            for (elements.items) |element| switch (element) {
                .button => |button| {
                    if (button.action == .add_editor_inventory_item and
                        button.payload.?.editor_inventory_slot == 13)
                    {
                        add_button_seen = true;
                    }
                    if (button.action == .select_editor_inventory_item_type) {
                        type_cells += 1;
                    }
                },
                else => {},
            };
        }
        try std.testing.expect(add_button_seen);
        try std.testing.expect(!name_field_seen);
        try std.testing.expectEqual(@as(usize, 0), type_cells);
    }
}

test "inspector team gradient: a team-0 entity type tints with the player gradient" {
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

    // Same type shape, differing only in team: 0 = helper (player
    // gradient), 2 = enemy team (enemy gradient). The Identity section
    // strip's panel color is the observable - the context's gradient[5].
    const helper_types = [_]types.EntityTypeDef{.{
        .id = "Helper",
        .template = .{ .name = "Helper", .team = 0 },
    }};
    const enemy_types = [_]types.EntityTypeDef{.{
        .id = "Brute",
        .template = .{ .name = "Brute", .team = 2 },
    }};

    for ([_]struct { editor: types.Editor, expected: types.Color }{
        .{ .editor = .{ .entity_types = &helper_types, .active_tool = .{ .entity_type = 0 } }, .expected = player_five },
        .{ .editor = .{ .entity_types = &enemy_types, .active_tool = .{ .entity_type = 0 } }, .expected = black },
    }) |case| {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, case.editor, theme, true, &ui_state);
        // All sections collapsed by default - the first content element
        // (index 4, after the toggle's 3 + the background panel) is the
        // Identity strip; its panel tint is the team gradient's index 5.
        try std.testing.expectEqualStrings("+ Identity", elements.items[6].text_label.text);
        try std.testing.expectEqual(case.expected, elements.items[4].nine_slice_panel.color);
    }
}
